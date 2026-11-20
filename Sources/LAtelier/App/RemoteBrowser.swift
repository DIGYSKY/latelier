import AppKit
import LAtelierCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Un transfert affiché en bas de l'explorateur.
struct RemoteTransfer: Identifiable {
    enum State: Equatable { case running, done, failed(String) }

    let id = UUID()
    var upload: Bool
    var names: [String]
    var bytes: Int64?
    var state: State = .running
    /// Où le trouver une fois téléchargé.
    var localFolder: URL?
    let started = Date()
}

/// Fichier distant ouvert pour modification (éditeur intégré ou externe).
struct RemoteEdit: Identifiable {
    let id = UUID()
    let file: RemoteFile
    /// Copie locale (celle qu'on modifie), et l'original tel que reçu.
    let local: URL
    let original: URL
    let originalText: String
    var text: String
    /// Ligne `ls -ld` du fichier à l'ouverture : s'il a changé sur le serveur, on prévient.
    var remoteStamp: String
    var external = false
    var localModified: Date?
}

/// Explorateur d'un serveur, en style « stockage en ligne » : parcourir, importer, télécharger,
/// modifier, renommer, supprimer (corbeille du serveur par défaut).
@Observable
final class RemoteBrowser {
    enum Layout: String { case grid, list }

    let alias: String
    private(set) var path: String?
    private(set) var home: String?
    private(set) var files: [RemoteFile] = []
    private(set) var loading = false
    private(set) var error: (title: String, advice: String)?
    var showHidden = false
    var layout: Layout = .grid
    var selection: Set<String> = []
    var transfers: [RemoteTransfer] = []
    /// Fichier ouvert dans l'éditeur intégré.
    var editing: RemoteEdit?
    /// Fichiers ouverts dans un éditeur externe, surveillés.
    private(set) var watched: [RemoteEdit] = []
    var notice: String?
    private var backStack: [String] = []

    @ObservationIgnored private weak var store: SSHStore?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var watchTimer: Timer?
    let commands: SSHCommands

    init(alias: String, store: SSHStore) {
        self.alias = alias
        self.store = store
        commands = SSHCommands(alias: alias)
    }

    var visibleFiles: [RemoteFile] {
        files.filter { showHidden || !$0.isHidden }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    var selectedFiles: [RemoteFile] { files.filter { selection.contains($0.id) } }
    var canGoBack: Bool { !backStack.isEmpty }

    private var runner: CommandRunner { store?.commandRunner ?? CommandRunner() }

    // MARK: Parcours

    func start() {
        guard path == nil else { return }
        loading = true
        let spec = commands.home
        let runner = runner
        task = Task {
            let result = try? await runner.run(spec, timeout: .seconds(25))
            guard !Task.isCancelled else { return }
            if let result, result.succeeded, let home = result.stdout.first(where: { $0.hasPrefix("/") }) {
                self.home = home
                store?.noteResult(alias, ok: true, output: "")
                load(home, remember: false)
            } else {
                fail(result)
            }
        }
    }

    func load(_ directory: String, remember: Bool = true) {
        if remember, let path, path != directory { backStack.append(path) }
        task?.cancel()
        loading = true
        let spec = commands.list(directory)
        let runner = runner
        task = Task {
            let result = try? await runner.run(spec, timeout: .seconds(30))
            guard !Task.isCancelled else { return }
            if let result, result.succeeded {
                files = RemoteListing.parse(result.stdout, directory: directory)
                path = directory
                error = nil
                selection = selection.intersection(files.map(\.id))
                loading = false
                store?.noteResult(alias, ok: true, output: "")
            } else {
                fail(result)
            }
        }
    }

    private func fail(_ result: CommandResult?) {
        let output = result.map { ($0.stderr + $0.stdout).joined(separator: "\n") } ?? "timed out"
        let failure = SSHFailure.explain(output)
        // Un dossier illisible n'est pas une panne de connexion.
        if path != nil, result != nil, !output.lowercased().contains("permission denied (publickey") && !output.contains("ssh:") {
            notice = "\(failure.title) : \(output.split(separator: "\n").last.map(String.init) ?? "")"
        } else {
            error = failure
            store?.noteResult(alias, ok: false, output: output)
        }
        loading = false
    }

    func refresh() {
        if let path { load(path, remember: false) } else { start() }
    }

    func retry() {
        error = nil
        path == nil ? start() : refresh()
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        load(previous, remember: false)
    }

    func goUp() {
        guard let path, path != "/" else { return }
        load(RemotePath.parent(path))
    }

    func goHome() {
        if let home { load(home) }
    }

    /// Double-clic : dossier → on entre ; lien → on essaie d'entrer ; fichier → éditeur si c'est du texte.
    func open(_ file: RemoteFile) {
        switch file.kind {
        case .directory, .link: load(file.path)
        case .file: edit(file)
        case .other: notice = "« \(file.name) » n’est ni un dossier ni un fichier ordinaire."
        }
    }

    // MARK: Transferts

    /// Envoie des fichiers du Mac. Sans conflit de nom : tout de suite (noté dans l'Historique) ;
    /// sinon, aperçu d'abord (des fichiers du serveur seraient remplacés).
    func upload(_ urls: [URL], into directory: String? = nil) {
        guard let target = directory ?? path, !urls.isEmpty else { return }
        let names = urls.map(\.lastPathComponent)
        let check = commands.existing(names, in: target)
        let runner = runner
        Task {
            // Les conflits sont vérifiés sur le serveur juste avant (la liste affichée peut être périmée).
            let result = try? await runner.run(check, timeout: .seconds(20))
            let verified = result?.succeeded == true
            let conflicts = verified ? (result?.stdout ?? []).filter { !$0.isEmpty } : []
            let bytes = urls.reduce(Int64(0)) { $0 + DiskUsage.measure($1).bytes }
            let summary: String
            if !verified {
                summary = "Copie dans \(target) (\(Format.bytes(bytes))). L’absence de fichiers du même nom n’a pas pu être vérifiée : un fichier existant serait remplacé."
            } else if conflicts.isEmpty {
                summary = "Copie dans \(target) (\(Format.bytes(bytes)))."
            } else {
                summary = "Remplacera sur le serveur : \(conflicts.joined(separator: ", ")). L’ancienne version sera perdue ; un dossier envoyé se mélange au dossier existant."
            }
            let plan = ActionPlan(
                title: "Envoyer \(names.count == 1 ? "« \(names[0]) »" : "\(names.count) éléments") sur \(alias)",
                summary: summary, kind: .serveur, risk: verified && conflicts.isEmpty ? .safe : .caution, reversible: false,
                steps: [.command(commands.upload(urls, to: target))], estimatedBytes: bytes
            )
            // Sans aperçu seulement si rien n'est remplacé (vérifié à l'instant).
            if verified && conflicts.isEmpty {
                run(plan, transfer: RemoteTransfer(upload: true, names: names, bytes: bytes))
            } else {
                store?.present(plan)
            }
        }
    }

    func download(_ files: [RemoteFile], to folder: URL? = nil) {
        guard !files.isEmpty else { return }
        let destination = folder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let conflicts = files.map(\.name).filter { FileManager.default.fileExists(atPath: destination.appendingPathComponent($0).path) }
        let bytes = files.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
        let plan = ActionPlan(
            title: "Télécharger \(files.count == 1 ? "« \(files[0].name) »" : "\(files.count) éléments") depuis \(alias)",
            summary: conflicts.isEmpty
                ? "Copie dans \(destination.abbreviatingHome())."
                : "Remplacera sur ce Mac, dans \(destination.abbreviatingHome()) : \(conflicts.joined(separator: ", ")).",
            kind: .serveur, risk: conflicts.isEmpty ? .safe : .caution, reversible: false,
            steps: [.command(commands.download(files.map(\.path), to: destination))]
        )
        if conflicts.isEmpty {
            run(plan, transfer: RemoteTransfer(upload: false, names: files.map(\.name), bytes: bytes > 0 ? bytes : nil, localFolder: destination))
        } else {
            store?.present(plan)
        }
    }

    func chooseDownloadFolder(_ files: [RemoteFile]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Télécharger ici"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let folder = panel.url { download(files, to: folder) }
    }

    func chooseUploads() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Importer"
        panel.message = "Fichiers ou dossiers à envoyer dans \(path ?? "le dossier courant")"
        if panel.runModal() == .OK { upload(panel.urls) }
    }

    private func run(_ plan: ActionPlan, transfer: RemoteTransfer? = nil) {
        guard let store else { return }
        let id = transfer?.id
        if let transfer { transfers.insert(transfer, at: 0) }
        Task {
            let entry = await store.execute(plan)
            guard let id, let index = transfers.firstIndex(where: { $0.id == id }) else { return }
            switch entry.outcome {
            case .success: transfers[index].state = .done
            case .failure(let reason), .partial(let reason):
                let output = entry.commands.map(\.output).joined(separator: "\n")
                transfers[index].state = .failed(output.isEmpty ? reason : SSHFailure.explain(output).title + " — " + (output.split(separator: "\n").last.map(String.init) ?? ""))
            case .cancelled: transfers[index].state = .failed("Annulé")
            }
        }
    }

    func clearFinishedTransfers() {
        transfers.removeAll { $0.state != .running }
    }

    // MARK: Dossiers, renommage, suppression

    func makeDirectory(_ name: String) {
        guard let path, RemotePath.isValidName(name) else { notice = "Nom invalide."; return }
        guard !files.contains(where: { $0.name == name }) else { notice = "« \(name) » existe déjà ici."; return }
        run(ActionPlan(title: "Nouveau dossier « \(name) » sur \(alias)", summary: "Dans \(path).", kind: .serveur, risk: .safe,
                       reversible: true, steps: [.command(commands.makeDirectory(RemotePath.join(path, name)))]))
    }

    /// Renommer ne remplace jamais : la commande refuse si le nom est pris.
    func rename(_ file: RemoteFile, to name: String) {
        guard name != file.name else { return }
        guard RemotePath.isValidName(name) else { notice = "Nom invalide."; return }
        let target = RemotePath.join(RemotePath.parent(file.path), name)
        run(ActionPlan(title: "Renommer « \(file.name) » en « \(name) » sur \(alias)", summary: "Dans \(RemotePath.parent(file.path)).",
                       kind: .serveur, risk: .safe, reversible: true, steps: [.command(commands.rename(file.path, to: target))]))
    }

    /// Corbeille du serveur par défaut (règle n° 2), toujours avec aperçu.
    func trash(_ files: [RemoteFile]) {
        guard !files.isEmpty else { return }
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "-")
        store?.present(ActionPlan(
            title: "Mettre \(Self.describe(files)) dans la corbeille du serveur",
            summary: "Déplacé sur \(alias) dans ~/.latelier-corbeille/\(stamp)/ : récupérable tant que ce dossier n’est pas vidé. Rien n’est supprimé définitivement.",
            kind: .serveur, risk: .caution, reversible: true, steps: [.command(commands.trash(files.map(\.path), stamp: stamp))]
        ))
    }

    func deletePermanently(_ files: [RemoteFile]) {
        guard !files.isEmpty else { return }
        store?.present(ActionPlan(
            title: "Supprimer définitivement \(Self.describe(files)) sur \(alias)",
            summary: "Les fichiers sont effacés du serveur, sans corbeille. Impossible de revenir en arrière.",
            kind: .serveur, risk: .danger, reversible: false, steps: [.command(commands.delete(files.map(\.path)))]
        ))
    }

    static func describe(_ files: [RemoteFile]) -> String {
        files.count == 1 ? "« \(files[0].name) »" : "\(files.count) éléments"
    }

    func copyPath(_ file: RemoteFile) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.path, forType: .string)
    }

    // MARK: Modification de fichiers

    static let editorLimit: Int64 = 2_000_000

    private var cacheFolder: URL {
        AppPaths.cacheDirectory.appendingPathComponent("ssh/\(alias)", isDirectory: true)
    }

    /// Ouvre dans l'éditeur intégré (texte de moins de 2 Mo).
    func edit(_ file: RemoteFile) {
        guard file.size <= Self.editorLimit else {
            notice = "« \(file.name) » fait \(Format.bytes(file.size)) : trop gros pour l’éditeur intégré. Ouvrez-le dans votre éditeur."
            return
        }
        fetchForEdit(file) { [weak self] edit in
            guard let self else { return }
            guard let edit else { return }
            editing = edit
        }
    }

    /// Ouvre dans l'éditeur choisi dans les Réglages ; chaque enregistrement est repéré et proposé à l'envoi.
    func editExternally(_ file: RemoteFile, editor: EditorApp?) {
        fetchForEdit(file, requireText: false) { [weak self] edit in
            guard let self, var edit else { return }
            edit.external = true
            edit.localModified = Self.modified(edit.local)
            watched.removeAll { $0.file.path == file.path }
            watched.append(edit)
            if let app = editor?.installedURL {
                NSWorkspace.shared.open([edit.local], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(edit.local)
            }
            startWatching()
        }
    }

    private func fetchForEdit(_ file: RemoteFile, requireText: Bool = true, then: @escaping (RemoteEdit?) -> Void) {
        let folder = cacheFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let local = folder.appendingPathComponent(file.name)
        let original = folder.appendingPathComponent(".original-" + file.name)
        let fetch = commands.fetch(file.path, to: local)
        let stat = commands.stat(file.path)
        let runner = runner
        loading = true
        Task {
            let stamp = (try? await runner.run(stat, timeout: .seconds(20)))?.stdout.first ?? ""
            let result = try? await runner.run(fetch, timeout: .seconds(120))
            loading = false
            guard let result, result.succeeded, let data = try? Data(contentsOf: local) else {
                let output = result.map { ($0.stderr + $0.stdout).joined(separator: "\n") } ?? "timed out"
                notice = "Impossible d’ouvrir « \(file.name) » : \(SSHFailure.explain(output).title)."
                then(nil)
                return
            }
            try? data.write(to: original)
            let text = String(data: data, encoding: .utf8)
            if requireText, text == nil || data.contains(0) {
                notice = "« \(file.name) » n’est pas un fichier texte. Ouvrez-le dans votre éditeur ou téléchargez-le."
                then(nil)
                return
            }
            then(RemoteEdit(file: file, local: local, original: original, originalText: text ?? "", text: text ?? "", remoteStamp: stamp))
        }
    }

    /// Enregistre sur le serveur, avec aperçu. Refuse si le fichier a changé là-bas entre-temps.
    func save(_ edit: RemoteEdit) {
        let stat = commands.stat(edit.file.path)
        let runner = runner
        Task {
            if !edit.external {
                do {
                    try edit.text.write(to: edit.local, atomically: true, encoding: .utf8)
                } catch {
                    notice = "Impossible de préparer l’envoi : \(error.localizedDescription)"
                    return
                }
            }
            let now = (try? await runner.run(stat, timeout: .seconds(20)))?.stdout.first ?? ""
            if !edit.remoteStamp.isEmpty, !now.isEmpty, now != edit.remoteStamp {
                notice = "« \(edit.file.name) » a été modifié sur le serveur depuis que vous l’avez ouvert. Rouvrez-le pour repartir de la version actuelle (votre texte reste dans l’éditeur)."
                return
            }
            let newText = (try? String(contentsOf: edit.local, encoding: .utf8)) ?? ""
            let (removed, added) = SSHConfig.diff(edit.originalText, newText)
            let change = edit.external && newText.isEmpty && edit.originalText.isEmpty
                ? "fichier modifié"
                : "\(added.count) ligne\(added.count > 1 ? "s" : "") ajoutée\(added.count > 1 ? "s" : "") ou modifiée\(added.count > 1 ? "s" : ""), \(removed.count) retirée\(removed.count > 1 ? "s" : "")"
            savingPath = edit.file.path
            // Envoi à côté, puis remplacement seulement si le fichier n'a pas changé entre-temps
            // (vérifié au moment de l'exécution, pas à l'ouverture de l'aperçu).
            let staged = RemotePath.join(RemotePath.parent(edit.file.path), ".\(edit.file.name).latelier-\(UUID().uuidString.prefix(8))")
            store?.present(ActionPlan(
                title: "Enregistrer « \(edit.file.name) » sur \(alias)",
                summary: "Remplace \(edit.file.path) (\(change)), en gardant ses droits. Refusé si le fichier change sur le serveur d’ici là. L’original reçu reste sur ce Mac : \(edit.original.abbreviatingHome()).",
                kind: .serveur, risk: .caution, reversible: false,
                steps: [.command(commands.put(edit.local, as: staged)),
                        .command(commands.replace(edit.file.path, with: staged, ifUnchanged: now.isEmpty ? edit.remoteStamp : now))]
            ))
        }
    }

    /// Fichier en cours d'enregistrement (aperçu ouvert).
    @ObservationIgnored private var savingPath: String?

    /// Une action vient d'être faite : on relit le dossier ; un enregistrement réussi devient la référence.
    func didRecord(_ entry: HistoryEntry) {
        if let path = savingPath, entry.outcome == .success, entry.title.hasPrefix("Enregistrer") {
            markSaved(path)
            if editing?.file.path == path, let text = editing?.text {
                editing = nil
                notice = "« \((path as NSString).lastPathComponent) » enregistré sur \(alias)."
                _ = text
            }
            savingPath = nil
        }
        refresh()
    }

    /// Après un envoi, la version du serveur devient la nouvelle référence (date et taille comprises).
    func markSaved(_ path: String) {
        guard let index = watched.firstIndex(where: { $0.file.path == path }) else { return }
        watched[index].localModified = Self.modified(watched[index].local)
        let stat = commands.stat(path)
        let runner = runner
        Task {
            if let line = (try? await runner.run(stat, timeout: .seconds(20)))?.stdout.first,
               let index = watched.firstIndex(where: { $0.file.path == path }) {
                watched[index].remoteStamp = line
            }
        }
    }

    /// Fichiers modifiés dans l'éditeur externe depuis la dernière fois.
    var pendingExternal: [RemoteEdit] {
        watched.filter { Self.modified($0.local) != $0.localModified }
    }

    func ignoreExternal(_ edit: RemoteEdit) {
        markSaved(edit.file.path)
    }

    func stopWatching(_ edit: RemoteEdit) {
        watched.removeAll { $0.id == edit.id }
    }

    private func startWatching() {
        guard watchTimer == nil else { return }
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Lire `watched` suffit à rafraîchir `pendingExternal` dans la vue.
                guard let self else { return }
                self.tick += 1
            }
        }
    }

    /// Change toutes les 2 s tant qu'on surveille des fichiers (recalcule `pendingExternal`).
    private(set) var tick = 0

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func stop() {
        task?.cancel()
        watchTimer?.invalidate()
        watchTimer = nil
    }

    // MARK: Icônes

    @ObservationIgnored private static var iconCache: [String: NSImage] = [:]

    static func icon(for file: RemoteFile) -> NSImage {
        let key = file.isDirectory ? "/dir" : file.kind == .link ? "/link" : file.fileExtension
        if let cached = iconCache[key] { return cached }
        let type: UTType
        switch file.kind {
        case .directory: type = .folder
        case .link: type = .aliasFile
        default: type = UTType(filenameExtension: file.fileExtension) ?? .data
        }
        let image = NSWorkspace.shared.icon(for: type)
        iconCache[key] = image
        return image
    }
}
