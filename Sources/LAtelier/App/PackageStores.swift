import AppKit
import LAtelierCore
import Observation

/// Paquets installés (toutes sources), ce qui est coché pour la mise à jour, et leurs tailles.
@Observable
final class PackageStore {
    private(set) var packages: [Package] = []
    private(set) var sources: Set<PackageSource> = []
    private(set) var problems: [String] = []
    private(set) var scanning = false
    private(set) var measuring = false
    private(set) var finishedAt: Date?
    private(set) var stale = true
    var selection: Set<String> = []
    private var task: Task<Void, Never>?

    var updates: [Package] { packages.filter(\.hasUpdate) }

    func run(_ work: @escaping @Sendable () async -> PackageScanner.Result) {
        task?.cancel()
        scanning = true
        task = Task {
            let result = await work()
            guard !Task.isCancelled else { return }
            let order = { (p: Package) in PackageSource.allCases.firstIndex(of: p.source) ?? 0 }
            packages = result.packages.sorted { (order($0), $0.name.lowercased()) < (order($1), $1.name.lowercased()) }
            sources = result.sources
            problems = result.problems
            selection = Set(packages.filter(\.selectedByDefault).map(\.id))
            finishedAt = .now
            stale = false
            scanning = false
            await measure()
        }
    }

    /// Tailles sur disque, mesurées après coup pour ne pas retarder la liste.
    private func measure() async {
        measuring = true
        let urls = packages.compactMap(\.location)
        let sizes = await DiskUsage.measure(urls)
        guard !Task.isCancelled else { return }
        packages = packages.map { package in
            var package = package
            if let url = package.location, let size = sizes[url], size.files > 0 { package.bytes = size.bytes }
            return package
        }
        measuring = false
    }

    func invalidate() { stale = true }
}

/// Résultat d'une lecture asynchrone (runtimes, services), avec son état.
@Observable
final class Loadable<Value: Sendable> {
    private(set) var value: Value?
    private(set) var loading = false
    private(set) var finishedAt: Date?
    private(set) var stale = true
    var problem: String?
    private var task: Task<Void, Never>?

    func run(_ work: @escaping @Sendable () async -> Value) {
        task?.cancel()
        loading = true
        task = Task {
            let result = await work()
            guard !Task.isCancelled else { return }
            value = result
            finishedAt = .now
            stale = false
            loading = false
        }
    }

    func invalidate() { stale = true }
}

extension AppModel {
    /// Chemins des apps ouvertes : leur mise à jour attend qu'elles soient quittées (règle n° 3).
    private var openAppPaths: Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
    }

    func scanPackages() {
        let open = openAppPaths
        let runner = runner
        packages.run { await PackageScanner(runner: runner, openApps: open).scan() }
    }

    func scanRuntimes() {
        let runner = runner
        let known = repos.repos.map(\.url)
        let roots = projectRoots
        runtimes.run {
            let projects = known.isEmpty ? RepoScanner(roots: roots).repositories() : known
            return await RuntimeScanner(runner: runner, projects: projects).scan()
        }
    }

    /// Lit les manifestes de tous les projets, interroge les registres et OSV, cherche les secrets.
    func scanAnalysis(force: Bool = false) {
        let runner = runner
        let known = repos.repos.map(\.url)
        let roots = projectRoots
        analysis.run {
            let projects = known.isEmpty ? RepoScanner(roots: roots).repositories() : known
            return await ProjectAnalyzer(runner: runner, projects: projects).analyze(force: force)
        }
    }

    func scanServices() {
        let runner = runner
        services.run {
            let result = await ServiceScanner(runner: runner).scan()
            return result.services
        }
    }

    /// Démarrer, arrêter, redémarrer : action immédiate, notée dans l'historique.
    func runService(_ action: BrewServices.Action, _ service: BrewService) {
        guard !serviceBusy.contains(service.name) else { return }
        serviceBusy.insert(service.name)
        let plan = ActionPlan(
            title: "\(action.label) \(service.name)", summary: "brew services",
            kind: .systeme, risk: .safe, reversible: true,
            commands: [BrewServices.command(action, service.name)]
        )
        Task {
            let entry = await runQuietly(plan)
            serviceBusy.remove(service.name)
            if case .failure(let message) = entry.outcome { services.problem = message } else { services.problem = nil }
            services.invalidate()
        }
    }
}

extension AppModel {
    func scanStartup() {
        let runner = runner
        let paths = Set(performance.processes.compactMap(\.path))
        startup.run { await StartupScanner(runner: runner).scan(runningPaths: paths) }
    }

    /// Les projets connus servent à relier un processus à son dépôt.
    var knownProjects: [URL] { repos.repos.map(\.url) }

    func ensureRepos() {
        if repos.stale && !repos.scanning { scanRepos() }
    }
}
