import AppKit
import LAtelierCore
import Observation
import SwiftUI

/// Onglets de la page d'un serveur.
enum ServerTab: String, CaseIterable {
    case monitor, files, configuration

    var label: String {
        switch self {
        case .monitor: "Moniteur"
        case .files: "Fichiers"
        case .configuration: "Configuration"
        }
    }
}

/// État d'une connexion, après un test.
enum HostStatus: Equatable {
    case checking
    case online(Date)
    case failed(title: String, advice: String)
}

/// Saisie de la feuille « Ajouter / Modifier une connexion ».
struct HostDraft: Identifiable {
    let id = UUID()
    /// Nom d'origine (modification) ; nil pour une nouvelle connexion.
    var original: String?
    var alias = ""
    var hostName = ""
    var user = ""
    var port = ""
    var identityFile = ""
    var proxyJump = ""
    var note = ""
    /// « Clé valeur » par ligne.
    var extra = ""
    var otherAliases: [String] = []

    init(original: String? = nil) {
        self.original = original
    }

    init(_ host: SSHHost, duplicate: Bool = false) {
        original = duplicate ? nil : host.alias
        alias = duplicate ? host.alias + "-copie" : host.alias
        hostName = host.hostName ?? ""
        user = host.user ?? ""
        port = host.port.map(String.init) ?? ""
        identityFile = host.identityFile ?? ""
        proxyJump = host.proxyJump ?? ""
        note = host.note ?? ""
        extra = host.extra.map { "\($0.key) \($0.value)" }.joined(separator: "\n")
        otherAliases = duplicate ? [] : host.otherAliases
    }

    var host: SSHHost {
        func clean(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let options = extra.split(whereSeparator: \.isNewline).compactMap { line -> SSHOption? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "=" || $0 == "\t" })
            return SSHOption(String(parts[0]), parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : "")
        }
        return SSHHost(
            alias: alias.trimmingCharacters(in: .whitespaces), otherAliases: otherAliases, hostName: clean(hostName), user: clean(user),
            port: clean(port).flatMap { Int($0) ?? -1 }, identityFile: clean(identityFile), proxyJump: clean(proxyJump),
            extra: options, note: clean(note)
        )
    }
}

/// Serveurs : connexions de ~/.ssh/config, leur état, et l'explorateur du serveur ouvert.
@Observable
final class SSHStore {
    private(set) var config = SSHConfig.load()
    private(set) var hosts: [SSHHost] = []
    private(set) var keys: [String] = []
    var status: [String: HostStatus] = [:]
    /// Serveur ouvert (sinon la liste), et son onglet.
    var openHost: String?
    var tab: ServerTab = .files
    var draft: HostDraft?
    /// Explorateur du serveur ouvert (gardé tant qu'on reste sur le même serveur).
    private(set) var browser: RemoteBrowser?
    /// Moniteur du serveur ouvert (connexion active seulement pendant que l'onglet est affiché).
    private(set) var monitor: RemoteMonitorStore?
    /// Configuration effective (`ssh -G`) du serveur ouvert.
    private(set) var effective: [String: String] = [:]

    @ObservationIgnored private var runner = CommandRunner()
    @ObservationIgnored private var preview: (ActionPlan) -> Void = { _ in }
    @ObservationIgnored private var record: (HistoryEntry) async -> Void = { _ in }
    @ObservationIgnored var preferences: ToolPreferences?

    init() {
        SSHCommands.prepareControlDirectory()
        reload()
    }

    func attach(runner: CommandRunner, preferences: ToolPreferences, preview: @escaping (ActionPlan) -> Void, record: @escaping (HistoryEntry) async -> Void) {
        self.runner = runner
        self.preferences = preferences
        self.preview = preview
        self.record = record
    }

    func reload() {
        config = SSHConfig.load()
        hosts = config.allHosts()
        keys = SSHKeys.list()
    }

    func host(_ alias: String) -> SSHHost? { hosts.first { $0.alias == alias } }

    /// Après une action enregistrée (connexion modifiée, fichier envoyé…).
    func afterAction(_ entry: HistoryEntry) {
        reload()
        browser?.didRecord(entry)
    }

    // MARK: Navigation

    func open(_ alias: String, tab: ServerTab = .monitor) {
        openHost = alias
        self.tab = tab
        if browser?.alias != alias {
            browser?.stop()
            monitor?.stop()
            browser = RemoteBrowser(alias: alias, store: self)
            monitor = RemoteMonitorStore(alias: alias, store: self)
        }
        if tab == .files { browser?.start() }
        loadEffective(alias)
    }

    func close() {
        openHost = nil
    }

    // MARK: Test et configuration effective

    func test(_ alias: String) {
        status[alias] = .checking
        let spec = SSHCommands(alias: alias).test
        let runner = runner
        Task {
            let result = try? await runner.run(spec, timeout: .seconds(20))
            if let result, result.succeeded {
                status[alias] = .online(.now)
            } else {
                let output = result.map { ($0.stderr + $0.stdout).joined(separator: "\n") } ?? "Délai dépassé (timed out)."
                let failure = SSHFailure.explain(output)
                status[alias] = .failed(title: failure.title, advice: failure.advice)
            }
        }
    }

    /// Réponse d'une commande distante : le statut suit (en ligne / en échec).
    func noteResult(_ alias: String, ok: Bool, output: String) {
        if ok {
            status[alias] = .online(.now)
        } else {
            let failure = SSHFailure.explain(output)
            status[alias] = .failed(title: failure.title, advice: failure.advice)
        }
    }

    private func loadEffective(_ alias: String) {
        let runner = runner
        Task {
            let result = try? await runner.run(CommandSpec("/usr/bin/ssh", ["-G", "--", alias]), timeout: .seconds(5))
            var values: [String: String] = [:]
            for line in result?.stdout ?? [] {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2, values[String(parts[0])] == nil else { continue }
                values[String(parts[0])] = String(parts[1])
            }
            effective = values
        }
    }

    // MARK: Terminal

    func openTerminal(_ alias: String, directory: String? = nil, terminal: TerminalApp? = nil) -> String? {
        let app = terminal ?? preferences?.terminal ?? .terminal
        do {
            try Launcher.openTerminal(app, directory: URL(fileURLWithPath: NSHomeDirectory()),
                                      command: SSHCommands(alias: alias).interactive(directory: directory))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Une commande distante dans le terminal (sudo, journaux) : le mot de passe éventuel se tape là.
    func openTerminal(_ alias: String, remote command: String) -> String? {
        do {
            try Launcher.openTerminal(preferences?.terminal ?? .terminal, directory: URL(fileURLWithPath: NSHomeDirectory()),
                                      command: SSHCommands(alias: alias).interactive(remote: command))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// `ssh-copy-id` dans le terminal : demande le mot de passe une fois, puis la clé suffit.
    func installKey(_ alias: String) -> String? {
        do {
            try Launcher.openTerminal(preferences?.terminal ?? .terminal, directory: URL(fileURLWithPath: NSHomeDirectory()),
                                      command: ["ssh-copy-id", alias])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Modifications de ~/.ssh/config (toujours avec aperçu)

    func problems(_ draft: HostDraft) -> [String] {
        draft.host.problems(existing: hosts, replacing: draft.original)
    }

    func save(_ draft: HostDraft) {
        let fresh = SSHConfig.load()
        let host = draft.host
        let after: String?
        if let original = draft.original {
            after = fresh.replacing(original, with: host)
        } else {
            after = fresh.adding(host)
        }
        guard let after else { return }
        let (removed, added) = SSHConfig.diff(fresh.text, after)
        let title = draft.original == nil ? "Ajouter la connexion « \(host.alias) »" : "Modifier la connexion « \(host.alias) »"
        let plan = ActionPlan(
            title: title,
            summary: "Écrit dans ~/.ssh/config. L’ancienne version du fichier est mise à la corbeille, pour pouvoir revenir en arrière.",
            kind: .serveur, risk: .safe, reversible: true,
            steps: [.editFile(FileEdit(file: fresh.url, before: fresh.text, after: after, added: added, removed: removed, backup: true))]
        )
        present(plan)
    }

    func delete(_ alias: String) {
        let fresh = SSHConfig.load()
        guard let after = fresh.removing(alias) else { return }
        let (removed, added) = SSHConfig.diff(fresh.text, after)
        let plan = ActionPlan(
            title: "Supprimer la connexion « \(alias) »",
            summary: "Retire le bloc de ~/.ssh/config. Le serveur, vos clés et known_hosts ne sont pas touchés. L’ancienne version du fichier va à la corbeille.",
            kind: .serveur, risk: .caution, reversible: true,
            steps: [.editFile(FileEdit(file: fresh.url, before: fresh.text, after: after, added: added, removed: removed, backup: true))]
        )
        if openHost == alias { openHost = nil }
        present(plan)
    }

    /// Laisse la feuille de saisie se fermer avant d'ouvrir l'aperçu.
    func present(_ plan: ActionPlan) {
        if draft != nil {
            draft = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [preview] in preview(plan) }
        } else {
            preview(plan)
        }
    }

    // MARK: Exécution directe (actions sans perte : dossier, renommage sans écrasement, transfert sans conflit)

    func execute(_ plan: ActionPlan) async -> HistoryEntry {
        let entry = await PlanExecutor(runner: runner).execute(plan)
        await record(entry)
        return entry
    }

    var commandRunner: CommandRunner { runner }
}
