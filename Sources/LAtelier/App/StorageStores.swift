import AppKit
import LAtelierCore
import Observation

/// Une app du Désinstalleur avec ses données et leurs tailles.
struct AppEntry: Sendable, Identifiable {
    struct PartSize: Sendable, Hashable, Identifiable {
        var part: AppInventory.Part
        /// `nil` : non mesuré (conteneur protégé par macOS).
        var bytes: Int64?
        var id: String { part.id }
    }

    var app: InstalledApp
    var parts: [PartSize]
    /// Cask Homebrew qui a installé l'app.
    var cask: String?

    var id: String { app.id }
    var total: Int64 { (app.bytes ?? 0) + parts.compactMap(\.bytes).reduce(0, +) }
}

extension AppModel {
    func scanCaches() {
        let runner = runner
        cacheScan.run { await PackageCacheScanner(runner: runner).scan() }
    }

    func scanLeftovers() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        deadLinks = DeadLinks.find()
        leftoverScan.run {
            let scanner = LeftoverScanner(installedIDs: AppInventory.allBundleIDs(), runningIDs: running)
            let leftovers = scanner.scan()
            let interrupted = scanner.interruptedInstalls()
            let sizes = await DiskUsage.measure(leftovers.flatMap(\.urls) + interrupted)
            var groups: [CleanupGroup] = []
            let items = scanner.items(leftovers, sizes: sizes.mapValues(\.bytes))
            let large = items.filter { $0.bytes >= 5_000_000 }, small = items.filter { $0.bytes < 5_000_000 }
            if !large.isEmpty {
                groups.append(CleanupGroup(id: "leftovers", title: "Apps désinstallées",
                                           detail: "Données dont l’app n’est plus installée · nom retrouvé depuis l’identifiant", items: large))
            }
            if !small.isEmpty {
                groups.append(CleanupGroup(id: "leftovers-small", title: "Petits restes (moins de 5 Mo)",
                                           detail: "Réglages et petits caches d’apps supprimées · cochés s’ils n’ont pas bougé depuis 3 mois",
                                           tone: .neutral, items: small))
            }
            let stale = interrupted.map { url -> CleanupItem in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let recent = Date().timeIntervalSince(modified) < 3600
                return CleanupItem(
                    id: "interrupted:" + url.path, name: "Installation Docker interrompue", detail: url.abbreviatingHome(),
                    detailIsPath: true, meta: "Du \(modified.formatted(.dateTime.day().month(.abbreviated)))",
                    risk: recent ? .protected : .safe, lockReason: recent ? "installation peut-être en cours" : nil,
                    selectedByDefault: !recent, entries: [CleanupItem.Entry(url: url, bytes: sizes[url]?.bytes ?? 0)]
                )
            }
            if !stale.isEmpty {
                groups.append(CleanupGroup(id: "interrupted", title: "Installations interrompues", detail: "com.docker.install/in_progress", items: stale))
            }
            return groups
        }
    }

    /// Plan de suppression des liens morts (mot de passe administrateur).
    var deadLinksPlan: ActionPlan? {
        guard let command = DeadLinks.removalCommand(deadLinks) else { return nil }
        return ActionPlan(
            title: "Supprimer \(deadLinks.count) lien\(deadLinks.count > 1 ? "s" : "") mort\(deadLinks.count > 1 ? "s" : "") dans /usr/local/bin",
            summary: "Ces liens visent des apps qui n’existent plus. /usr/local/bin appartient au système : macOS demandera le mot de passe administrateur.",
            kind: .nettoyage, risk: .caution, reversible: false, steps: [.command(command)],
            skipped: deadLinks.map { "\($0.url.lastPathComponent) → \(DeadLinks.appName($0))" }
        )
    }

    func scanDocker() {
        let runner = runner
        docker.run { await DockerScanner.scan(runner: runner) }
    }

    var dockerPath: String { runner.locator.locate("docker")?.path ?? "docker" }

    func scanInstalledApps() {
        let runner = runner
        installedApps.run {
            var apps = AppInventory.installed()
            // Casks Homebrew : lus sur la machine, sans réseau.
            let packages = await PackageScanner(runner: runner, checkRemote: false).scan().packages
            var casks: [String: String] = [:]
            for package in packages where package.isCask {
                if let url = package.appURL { casks[url.standardizedFileURL.path] = package.identifier }
            }
            let sizes = await DiskUsage.measure(apps.map(\.url))
            var entries: [AppEntry] = []
            for index in apps.indices {
                apps[index].bytes = sizes[apps[index].url]?.bytes
                let app = apps[index]
                let parts = AppInventory.parts(bundleID: app.bundleID, name: app.name)
                let measured = await DiskUsage.measure(parts.filter { !$0.isContainer }.map(\.url))
                entries.append(AppEntry(
                    app: app,
                    parts: parts.map { AppEntry.PartSize(part: $0, bytes: $0.isContainer ? nil : measured[$0.url]?.bytes ?? 0) },
                    cask: casks[app.url.standardizedFileURL.path]
                ))
            }
            return entries
        }
    }

    /// L'app tourne-t-elle ? (pour la quitter proprement avant de la désinstaller)
    func runningTarget(for app: InstalledApp) -> ProcessTarget? {
        let path = app.url.standardizedFileURL.path
        guard let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL.path == path }) else { return nil }
        return ProcessTarget.current(pid: running.processIdentifier, name: app.name, isApp: true)
    }

    func scanOverview() {
        let runner = runner
        let allow = preferences.allowPersonalFolders
        let roots = projectRoots
        overview.run { await DiskOverviewScanner(runner: runner, allowPersonal: allow, projectRoots: roots).scan() }
    }

    /// Toutes les analyses (réglage « Tout analyser au démarrage », ou bouton Analyser de la vue d'ensemble).
    func scanEverything() {
        scanOverview()
        scanSystem()
        scanDev()
        scanCaches()
        scanLeftovers()
        if preferences.includeDocker { scanDocker() }
        scanInstalledApps()
        ensureRepos()
        scanPackages()
        scanRuntimes()
        scanServices()
        scanAnalysis()
        scanStartup()
        Task {
            // La couverture a besoin de la liste des dépôts.
            while repos.scanning { try? await Task.sleep(for: .milliseconds(300)) }
            scanCoverage()
        }
    }

    /// Accord explicite pour Bureau, Documents, Téléchargements : macOS demandera ensuite l'autorisation.
    func allowPersonalFolders() {
        preferences.allowPersonalFolders = true
        overview.invalidate()
        explorer.invalidate()
        sonar.invalidate()
    }
}

/// Explorateur : contenu de chaque dossier visité, gardé tant que rien n'est supprimé.
@Observable
final class ExplorerStore {
    private(set) var path: [URL] = [URL(fileURLWithPath: NSHomeDirectory())]
    private(set) var nodes: [String: [FolderNode]] = [:]
    private(set) var loading: Set<String> = []
    var selected: String?

    var current: URL { path.last! }

    func open(_ url: URL) {
        if let index = path.firstIndex(of: url) {
            path = Array(path.prefix(index + 1))
        } else {
            path.append(url)
        }
        selected = nil
    }

    /// Ouvre directement un dossier : le fil d'Ariane part du dossier personnel s'il en fait partie.
    func reveal(_ url: URL) {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if url.path.hasPrefix(home.path + "/") {
            var trail = [home]
            var current = home
            for component in url.path.dropFirst(home.path.count + 1).split(separator: "/") {
                current = current.appending(path: String(component))
                trail.append(current)
            }
            path = trail
        } else {
            path = [url]
        }
        selected = nil
    }

    func load(_ url: URL, allowPersonal: Bool, projectRoots: [URL]) {
        guard nodes[url.path] == nil, !loading.contains(url.path) else { return }
        loading.insert(url.path)
        Task {
            let result = await FolderExplorer.children(of: url, allowPersonal: allowPersonal, projectRoots: projectRoots)
            nodes[url.path] = result
            loading.remove(url.path)
        }
    }

    func invalidate() {
        nodes = [:]
    }
}

/// Sonar : fichiers de la zone, décisions (garder, corbeille, passer), corbeille en attente d'aperçu.
@Observable
final class SonarStore {
    var zone: SonarZone = .home
    var lens: SonarLens = .all
    private(set) var files: [SonarFile] = []
    private(set) var scanning = false
    private(set) var scannedZone: SonarZone?
    var selected: String?
    /// Ordre des décisions, pour « Annuler la dernière ».
    private(set) var decisions: [(id: String, action: Action)] = []
    var goal: Int64 = 10_000_000_000
    /// Taille minimale d'un fichier proposé.
    var minimumBytes: Int64 = 50_000_000
    /// Dossiers parcourus lors du dernier balayage.
    private(set) var scannedRoots: [URL] = []
    /// Libéré par les corbeilles déjà faites dans cette session.
    private(set) var freed: Int64 = 0
    private var task: Task<Void, Never>?

    enum Action { case keep, trash, skip }

    func scan(_ zone: SonarZone, allowPersonal: Bool, excluded: [URL], installedApps: Set<String>) {
        task?.cancel()
        scanning = true
        self.zone = zone
        task = Task {
            // Captures et tests : LATELIER_SONAR_HOME=/dossier/de/test balaie ce dossier à la place du dossier personnel.
            let home = ProcessInfo.processInfo.environment["LATELIER_SONAR_HOME"].map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: NSHomeDirectory())
            let scanner = SonarScanner(home: home, allowPersonal: allowPersonal || home.path != NSHomeDirectory(),
                                       minimumBytes: minimumBytes, excluded: excluded, installedApps: installedApps)
            scannedRoots = scanner.roots(zone).map(\.0)
            let found = await scanner.scan(zone)
            guard !Task.isCancelled else { return }
            files = found
            scannedZone = zone
            decisions = []
            selected = nil
            scanning = false
        }
    }

    func invalidate() { scannedZone = nil }

    private func decided(_ id: String) -> Bool { decisions.contains { $0.id == id } }

    /// Fichiers encore à trier, dans le filtre.
    var live: [SonarFile] { files.filter { !decided($0.id) && lens.matches($0) } }

    var current: SonarFile? {
        let list = live
        return list.first { $0.id == selected } ?? list.max { $0.bytes < $1.bytes }
    }

    /// En attente de la corbeille (aperçu obligatoire avant).
    var staged: [SonarFile] {
        decisions.filter { $0.action == .trash }.compactMap { decision in files.first { $0.id == decision.id } }
    }

    var sortedCount: Int { decisions.filter { $0.action != .skip }.count }

    func decide(_ action: Action) {
        guard let file = current else { return }
        decisions.append((file.id, action))
        selected = live.max { $0.bytes < $1.bytes }?.id
    }

    func undo() {
        guard !decisions.isEmpty else { return }
        selected = decisions.removeLast().id
    }

    /// Après un passage à la corbeille : les fichiers partis sont retirés, la jauge avance.
    func reconcile() {
        let gone = files.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
        guard !gone.isEmpty else { return }
        freed += gone.reduce(0) { $0 + $1.bytes }
        let ids = Set(gone.map(\.id))
        files.removeAll { ids.contains($0.id) }
        decisions.removeAll { ids.contains($0.id) }
    }

    var trashPlan: ActionPlan? {
        let list = staged
        guard !list.isEmpty else { return nil }
        let total = list.reduce(0) { $0 + $1.bytes }
        var plan = ActionPlan(
            title: "Sonar : \(list.count) fichier\(list.count > 1 ? "s" : "") à la corbeille",
            summary: "Tout part dans la corbeille de macOS : rien n’est supprimé définitivement depuis le Sonar.",
            kind: .nettoyage, risk: .caution, reversible: true,
            steps: list.map { .remove($0.url, bytes: $0.bytes, permanently: false) }, estimatedBytes: total
        )
        plan.allowsPermanent = false
        return plan
    }
}
