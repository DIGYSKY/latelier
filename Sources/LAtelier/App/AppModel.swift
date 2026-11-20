import AppKit
import LAtelierCore
import Observation
import SwiftUI

/// État global : écran affiché, historique, action en attente d'aperçu, analyses.
@Observable
final class AppModel {
    var selection: Page = .accueil
    var history: [HistoryEntry] = []
    var historyError: String?
    /// Action montrée dans la feuille d'aperçu. Toute action qui modifie passe par là.
    var pendingPlan: ActionPlan?

    /// Dossiers où chercher les projets (partagés avec l'onglet Projets).
    private(set) var projectRoots: [URL]

    let systemScan = ScanStore()
    let devScan = ScanStore()
    /// Stockage › Caches, Applications › Nettoyage.
    let cacheScan = ScanStore()
    let leftoverScan = ScanStore()
    /// Liens de /usr/local/bin vers une app supprimée.
    var deadLinks: [DeadLinks.Link] = []
    /// Stockage › Docker, et ce qui y est coché.
    let docker = Loadable<DockerReport>()
    var dockerSelection: Set<String> = []
    /// Applications › Désinstalleur.
    let installedApps = Loadable<[AppEntry]>()
    /// Stockage › Vue d’ensemble.
    let overview = Loadable<DiskOverview>()
    let explorer = ExplorerStore()
    let sonar = SonarStore()
    let repos = RepoStore()
    let packages = PackageStore()
    let runtimes = Loadable<[RuntimeLanguage]>()
    let services = Loadable<[BrewService]>()
    /// Dépendances, failles (OSV), secrets et hygiène de tous les projets.
    let analysis = Loadable<ProjectAnalysis>()
    /// Services pour lesquels une commande est en cours.
    var serviceBusy: Set<String> = []
    /// Éléments de connexion, agents et démons.
    let startup = Loadable<StartupScanner.Result>()

    let runner = CommandRunner()
    let historyStore: HistoryStore
    /// Gestionnaire des tâches (échantillonnage seulement quand un écran Performance est affiché).
    let performance: PerformanceMonitor
    let preferences = ToolPreferences()
    /// Commandes de projet en cours et derniers résultats.
    @ObservationIgnored private(set) var commandCenter: CommandCenter!
    @ObservationIgnored private(set) var recorder: RecorderService!
    /// Couverture de tests par projet.
    let coverage = Loadable<[CoverageEntry]>()
    /// Actualités, avis de sécurité et croisement avec la machine.
    @ObservationIgnored private(set) var news: NewsStore!
    /// Demande « Ouvrir dans Claude » en attente (feuille).
    var pendingClaude: ClaudeRequest?
    /// Fiche d'un processus (Performance).
    var processDetail: ProcessDetailRequest?
    /// Action refusée avant l'aperçu, avec la raison (paquet requis par un autre…).
    var actionNotice: String?
    /// Erreur d'ouverture d'un terminal ou d'un éditeur.
    var launchError: String?
    private static let rootsKey = "projectRoots"

    init(historyStore: HistoryStore = HistoryStore()) {
        self.historyStore = historyStore
        performance = PerformanceMonitor(runner: runner)
        let saved = UserDefaults.standard.stringArray(forKey: Self.rootsKey)
        projectRoots = saved.map { $0.map { URL(fileURLWithPath: $0) } } ?? DevArtifactScanner.defaultRoots()
        // Ouvre directement un écran (captures, développement) : LATELIER_PAGE=sonar
        if let raw = ProcessInfo.processInfo.environment["LATELIER_PAGE"], let page = Page(rawValue: raw) {
            selection = page
        }
        commandCenter = CommandCenter(runner: runner) { [weak self] entry in await self?.record(entry) }
        recorder = RecorderService(preferences: preferences) { [weak self] in self?.knownProjects ?? [] }
        recorder.start()
        news = NewsStore(preferences: preferences)
        news.start { [weak self] in await self?.newsInventory() ?? ([], []) }
        packages.offerMajors = preferences.offerMajors
        startBackgroundChecks()
        if preferences.scanAtLaunch { scanEverything() }
    }

    func preview(_ plan: ActionPlan) {
        // Méthode par défaut choisie dans Réglages › Stockage (modifiable dans l'aperçu).
        if preferences.permanentByDefault, plan.allowsPermanent, plan.removesFiles, !plan.removesPermanently {
            pendingPlan = plan.removing(permanently: true)
        } else {
            pendingPlan = plan
        }
    }

    // MARK: - Analyses

    func scanSystem() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        systemScan.run {
            await SystemScanner(runningBundleIDs: running).scan()
        } transform: { groups in
            groups.map { group in
                var group = group
                group.items = group.items.map { item in
                    var item = item
                    item.name = Self.appName(forBundleID: item.name) ?? item.name
                    return item
                }
                return group
            }
        }
    }

    func scanDev() {
        let roots = projectRoots
        let runner = runner
        let months = preferences.inactiveMonths
        let excluded = excludedFolders
        devScan.run {
            let busy = await ProcessDirectories(runner: runner).current()
            var scanner = DevArtifactScanner(roots: roots, busyDirectories: busy)
            scanner.inactiveAfter = TimeInterval(months) * 30 * 86_400
            return await scanner.scan()
        } transform: { groups in
            Self.excluding(groups, excluded)
        }
    }

    /// Dossiers exclus dans Réglages › Stockage (chemins absolus).
    var excludedFolders: [URL] {
        preferences.excludedFolders.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }

    /// Retire des groupes ce qui est sous un dossier exclu.
    static func excluding(_ groups: [CleanupGroup], _ excluded: [URL]) -> [CleanupGroup] {
        guard !excluded.isEmpty else { return groups }
        let prefixes = excluded.map { $0.standardizedFileURL.path }
        func isExcluded(_ url: URL) -> Bool { prefixes.contains { url.path == $0 || url.path.hasPrefix($0 + "/") } }
        return groups.compactMap { group in
            var group = group
            group.items = group.items.compactMap { item in
                var item = item
                item.entries = item.entries.filter { !isExcluded($0.url) }
                return item.entries.isEmpty && item.action == .remove && item.displayBytes == nil ? nil : item
            }
            return group.items.isEmpty ? nil : group
        }
    }

    /// Recherche des dépôts, à la profondeur choisie dans les réglages.
    var repoScanner: RepoScanner { RepoScanner(roots: projectRoots, maxDepth: preferences.repoDepth) }

    /// « com.spotify.client » → « Spotify », si l'app est installée.
    private static func appName(forBundleID id: String) -> String? {
        guard id.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func addProjectRoot(_ url: URL) {
        guard !projectRoots.contains(url) else { return }
        projectRoots.append(url)
        saveRoots()
        devScan.invalidate()
        repos.invalidate()
    }

    func removeProjectRoot(_ url: URL) {
        projectRoots.removeAll { $0 == url }
        saveRoots()
        devScan.invalidate()
        repos.invalidate()
    }

    // MARK: - Projets

    func scanRepos() {
        let scanner = repoScanner
        let git = GitClient(runner: runner)
        repos.run { await scanner.scan(git: git) }
    }

    /// Exécute sans aperçu une action sans risque (fetch), mais la note dans l'historique.
    @discardableResult
    func runQuietly(_ plan: ActionPlan) async -> HistoryEntry {
        let entry = await PlanExecutor(runner: runner).execute(plan)
        await record(entry)
        return entry
    }

    func fetchAll() {
        let targets = repos.repos.filter(\.hasRemote)
        guard !targets.isEmpty, !repos.fetching else { return }
        repos.fetching = true
        Task {
            let entry = await runQuietly(GitClient.fetchPlan(targets))
            repos.fetching = false
            repos.message = switch entry.outcome {
            case .success: "Fetch terminé · \(targets.count) dépôt(s) à jour"
            case .partial(let text), .failure(let text): text
            case .cancelled: "Fetch annulé"
            }
        }
    }

    private func saveRoots() {
        UserDefaults.standard.set(projectRoots.map(\.path), forKey: Self.rootsKey)
    }

    // MARK: - Historique

    func reloadHistory() async {
        do {
            history = try await historyStore.all()
            historyError = nil
        } catch {
            historyError = "Historique illisible : \(error.localizedDescription)"
        }
    }

    /// Note une action terminée ; les analyses deviennent périmées.
    func record(_ entry: HistoryEntry) async {
        do {
            try await historyStore.append(entry)
        } catch {
            historyError = "Impossible d’enregistrer l’historique : \(error.localizedDescription)"
        }
        if entry.kind == .nettoyage {
            recorder.reload()
            systemScan.invalidate()
            devScan.invalidate()
            cacheScan.invalidate()
            leftoverScan.invalidate()
            docker.invalidate()
            installedApps.invalidate()
            overview.invalidate()
            explorer.invalidate()
            sonar.reconcile()
        }
        if entry.kind == .git {
            repos.invalidate()
            analysis.invalidate()
        }
        if entry.kind == .paquet || entry.kind == .git {
            news.inventoryStale = true
        }
        if entry.kind == .paquet {
            packages.invalidate()
            runtimes.invalidate()
            analysis.invalidate()
        }
        if entry.kind == .systeme {
            services.invalidate()
            startup.invalidate()
        }
        if entry.kind == .processus { performance.refreshNow() }
        if entry.kind == .commande {
            coverage.invalidate()
            commandCenter.reload()
        }
        await reloadHistory()
    }

    func clearHistory() async {
        do {
            try await historyStore.clear()
        } catch {
            historyError = "Impossible de vider l’historique : \(error.localizedDescription)"
        }
        await reloadHistory()
    }
}

/// Résultat d'une analyse de nettoyage, et ce que l'utilisateur a coché.
@Observable
final class ScanStore {
    private(set) var groups: [CleanupGroup] = []
    private(set) var scanning = false
    private(set) var finishedAt: Date?
    private(set) var duration: TimeInterval = 0
    /// Vrai quand les résultats ne reflètent plus le disque (après un nettoyage).
    private(set) var stale = true
    var selection: Set<String> = []
    private var task: Task<Void, Never>?

    func run(
        _ work: @escaping @Sendable () async -> [CleanupGroup],
        transform: @escaping ([CleanupGroup]) -> [CleanupGroup] = { $0 }
    ) {
        task?.cancel()
        scanning = true
        let start = Date()
        task = Task {
            let result = await work()
            guard !Task.isCancelled else { return }
            groups = transform(result)
            selection = Set(groups.flatMap(\.items).filter { $0.selectedByDefault && !$0.isLocked }.map(\.id))
            duration = Date().timeIntervalSince(start)
            finishedAt = .now
            stale = false
            scanning = false
        }
    }

    func cancel() {
        task?.cancel()
        scanning = false
    }

    func invalidate() {
        stale = true
    }

    var items: [CleanupItem] { groups.flatMap(\.items) }
}


/// Dépôts git détectés et leur état.
@Observable
final class RepoStore {
    private(set) var repos: [RepoStatus] = []
    private(set) var scanning = false
    private(set) var finishedAt: Date?
    private(set) var stale = true
    var selectedID: String?
    var fetching = false
    /// Dernier résultat d'une action rapide (fetch), affiché sous le titre.
    var message: String?
    private var task: Task<Void, Never>?

    var selected: RepoStatus? { repos.first { $0.id == selectedID } ?? repos.first }

    func run(_ work: @escaping @Sendable () async -> [RepoStatus]) {
        task?.cancel()
        scanning = true
        task = Task {
            let result = await work()
            guard !Task.isCancelled else { return }
            repos = result
            finishedAt = .now
            stale = false
            scanning = false
        }
    }

    func invalidate() {
        stale = true
    }
}
