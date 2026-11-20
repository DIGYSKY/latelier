import Foundation
import LAtelierCore
import Observation
import UserNotifications

/// News : sources, articles gardés sur le Mac, lus et favoris, croisement avec les projets et paquets.
@Observable
final class NewsStore {
    private(set) var state = NewsState()
    private(set) var loaded = false
    private(set) var refreshing = false
    /// Sujets déduits des projets et paquets.
    private(set) var autoTopics: [NewsTopic] = []
    /// Ce qui touche la machine, par article.
    private(set) var matches: [String: [NewsMatch]] = [:]
    private(set) var inventoryReady = false
    var message: String?

    @ObservationIgnored private var inventory = NewsInventory()
    @ObservationIgnored private let store = JSONStore<NewsState>(name: "news.json", fallback: NewsState())
    @ObservationIgnored private let fetcher = NewsFetcher()
    @ObservationIgnored private let preferences: ToolPreferences
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(preferences: ToolPreferences) {
        self.preferences = preferences
    }

    // MARK: Chargement

    /// Charge l'état, puis vérifie toutes les 15 min si une lecture est due.
    func start(inventory provider: @escaping () async -> (manifests: [ProjectManifest], packages: [Package])) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            guard let self else { return }
            state = await store.load()
            loaded = true
            recomputeMatches()
            let source = await provider()
            updateInventory(manifests: source.manifests, packages: source.packages)
            while !Task.isCancelled {
                let interval = TimeInterval(preferences.newsIntervalHours * 3600)
                let paused = preferences.pauseOnBattery && PowerSnapshot.current().onBattery
                if !refreshing, !paused, state.lastRefresh.map({ Date().timeIntervalSince($0) >= interval }) ?? true {
                    await refresh()
                }
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    func updateInventory(manifests: [ProjectManifest], packages: [Package]) {
        inventory = NewsInventory(manifests: manifests, packages: packages)
        autoTopics = NewsTopics.detect(manifests: manifests, packages: packages)
        inventoryReady = true
        inventoryStale = false
        recomputeMatches()
    }

    @ObservationIgnored private var matchTask: Task<Void, Never>?

    /// Croisement en arrière-plan : la fenêtre ne se fige pas pendant le calcul.
    private func recomputeMatches() {
        let items = state.items
        let inventory = inventory
        matchTask?.cancel()
        rebuild()
        matchTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> [String: [NewsMatch]] in
                var result: [String: [NewsMatch]] = [:]
                for item in items {
                    let found = NewsMatcher.matches(item, in: inventory)
                    if !found.isEmpty { result[item.id] = found }
                }
                return result
            }.value
            guard let self, !Task.isCancelled else { return }
            matches = result
            rebuild()
        }
    }

    // MARK: Sources

    var sources: [NewsSource] { state.custom + NewsCatalog.builtIn }

    var followed: [NewsTopic] {
        autoTopics.filter { !state.hiddenTopics.contains($0.name) } + state.manualTopics.map { NewsTopic(name: $0, auto: false) }
    }

    private var followedNames: Set<String> { Set(followed.map(\.name)) }

    func isEnabled(_ source: NewsSource) -> Bool {
        // Réglages › Confidentialité : pas de requêtes vers GitHub Advisories.
        if source.kind == .githubAdvisories && !preferences.remoteAdvisories { return false }
        return state.overrides[source.id] ?? NewsCatalog.enabledByDefault(source, topics: followedNames)
    }

    var enabledSources: [NewsSource] { sources.filter(isEnabled) }

    func setEnabled(_ source: NewsSource, _ on: Bool) {
        state.overrides[source.id] = on
        rebuild()
        save()
        // Une source activée est lue tout de suite si elle n'a jamais été lue.
        if on, state.status[source.id]?.lastSuccess == nil { Task { await refresh(only: [source]) } }
    }

    func source(_ id: String) -> NewsSource? { sources.first { $0.id == id } }

    /// Marque le croisement comme à refaire (paquets ou dépôts changés).
    @ObservationIgnored var inventoryStale = true

    /// Vérifie que l'adresse donne un flux RSS ou Atom, puis l'ajoute.
    func addSource(_ address: String) async -> String? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), url.host != nil else {
            return String(localized: "Adresse invalide.")
        }
        guard !sources.contains(where: { $0.url == url }) else { return "Ce flux est déjà dans la liste." }
        do {
            let feed = try await fetcher.probe(url)
            let id = "custom-" + UUID().uuidString.prefix(8).lowercased()
            let source = NewsSource(id: id, name: feed.title ?? url.host ?? String(localized: "Flux"), url: url, category: .personnel, builtIn: false)
            state.custom.insert(source, at: 0)
            await refresh(only: [source])
            return nil
        } catch {
            return String(localized: "Lecture impossible : \(error.localizedDescription)")
        }
    }

    func removeSource(_ source: NewsSource) {
        guard !source.builtIn else { return }
        state.custom.removeAll { $0.id == source.id }
        state.overrides[source.id] = nil
        state.status[source.id] = nil
        state.items.removeAll { $0.sourceID == source.id && !state.starred.contains($0.id) }
        save()
        recomputeMatches()
    }

    // MARK: Sujets

    func addTopic(_ name: String) {
        let topic = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return }
        if state.hiddenTopics.remove(topic) == nil, !followed.contains(where: { $0.name.caseInsensitiveCompare(topic) == .orderedSame }) {
            state.manualTopics.append(topic)
        }
        rebuild()
        save()
    }

    func removeTopic(_ topic: NewsTopic) {
        if topic.auto { state.hiddenTopics.insert(topic.name) } else { state.manualTopics.removeAll { $0 == topic.name } }
        rebuild()
        save()
    }

    // MARK: Lecture

    func refresh(only: [NewsSource]? = nil) async {
        let targets = only ?? enabledSources
        guard !targets.isEmpty else { return }
        if only == nil { refreshing = true }
        let first = state.lastRefresh == nil
        let outcomes = await fetcher.fetch(targets, ecosystems: inventory.ecosystems)
        var fresh: [NewsItem] = []
        let now = Date()
        for outcome in outcomes {
            var status = state.status[outcome.sourceID] ?? NewsSourceStatus()
            status.lastAttempt = now
            status.error = outcome.error
            if !outcome.items.isEmpty || outcome.error == nil {
                status.lastSuccess = now
                status.count = outcome.items.count
                status.format = outcome.format ?? status.format
            }
            state.status[outcome.sourceID] = status
            fresh += outcome.items
        }
        let added = state.merge(fresh, now: now)
        if only == nil { state.lastRefresh = now }
        // Les nouveaux articles sont croisés tout de suite (notifications), le reste en arrière-plan.
        for item in added {
            let found = NewsMatcher.matches(item, in: inventory)
            if !found.isEmpty { matches[item.id] = found }
        }
        recomputeMatches()
        let failed = outcomes.filter { $0.error != nil && $0.items.isEmpty }.count
        message = failed > 0 ? (failed > 1 ? String(localized: "\(failed) sources en erreur : voir Sources.") : String(localized: "\(failed) source en erreur : voir Sources.")) : nil
        if !first {
            notify(added)
        } else {
            state.notified.formUnion(added.map(\.id))
            // Première lecture : l'arriéré de plus de 3 jours compte comme lu, sauf ce qui vous concerne.
            let limit = now.addingTimeInterval(-3 * 86_400)
            state.read.formUnion(added.filter { $0.date < limit && matches[$0.id] == nil }.map(\.id))
        }
        save()
        if only == nil { refreshing = false }
    }

    // MARK: Lu, favoris

    func isRead(_ item: NewsItem) -> Bool { state.read.contains(item.id) }
    func isStarred(_ item: NewsItem) -> Bool { state.starred.contains(item.id) }

    func markRead(_ item: NewsItem) {
        guard state.read.insert(item.id).inserted else { return }
        rebuild()
        save()
    }

    func markUnread(_ item: NewsItem) {
        guard state.read.remove(item.id) != nil else { return }
        rebuild()
        save()
    }

    func markAllRead(_ items: [NewsItem]) {
        state.read.formUnion(items.map(\.id))
        rebuild()
        save()
    }

    func toggleStar(_ item: NewsItem) {
        if state.starred.remove(item.id) == nil { state.starred.insert(item.id) }
        rebuild()
        save()
    }

    // MARK: Filtres (calculés une fois par changement, pas à chaque rendu)

    struct Derived {
        var visible: [NewsItem] = []
        var forYou: [NewsItem] = []
        var cyber: [NewsItem] = []
        var languages: [NewsItem] = []
        var general: [NewsItem] = []
        var all: [NewsItem] = []
        var favorites: [NewsItem] = []
        var unreadForYou = 0
        var topAlert: NewsItem?
        /// Avis graves non lus qui touchent la machine (Accueil, barre des menus).
        var concerningSevere = 0
    }

    private(set) var derived = Derived()
    @ObservationIgnored private var sourceNames: [String: String] = [:]

    var visibleItems: [NewsItem] { derived.visible }
    var forYou: [NewsItem] { derived.forYou }
    var cyber: [NewsItem] { derived.cyber }
    var languages: [NewsItem] { derived.languages }
    var general: [NewsItem] { derived.general }
    var all: [NewsItem] { derived.all }
    var favorites: [NewsItem] { derived.favorites }
    /// Non lues de « Pour vous » : la pastille de la barre latérale.
    var unreadForYou: Int { derived.unreadForYou }
    /// L'alerte la plus grave qui touche la machine (bandeau rouge).
    var topAlert: NewsItem? { derived.topAlert }
    var concerningSevere: Int { derived.concerningSevere }

    func sourceName(_ id: String) -> String { sourceNames[id] ?? id }

    func concerns(_ item: NewsItem) -> Bool { matches[item.id] != nil }
    func confirmed(_ item: NewsItem) -> Bool { matches[item.id]?.contains(where: \.confirmed) == true }

    /// Recalcule toutes les listes (quelques millisecondes pour 1 500 articles).
    private func rebuild() {
        sourceNames = Dictionary(sources.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let enabled = Set(enabledSources.map(\.id))
        let read = state.read, starred = state.starred
        let topics = followedNames
        let manual = state.manualTopics
        var d = Derived()
        d.visible = state.items.filter { enabled.contains($0.sourceID) || starred.contains($0.id) }
        let shown = { (item: NewsItem) in item.sourceID != "gha" || item.isSevere || self.matches[item.id] != nil }
        var mine: [NewsItem] = [], rest: [NewsItem] = []
        for item in d.visible {
            let concerned = matches[item.id] != nil
            var include = concerned
            if !include {
                switch item.category {
                case .langage: include = item.language.map(topics.contains) ?? false
                case .personnel: include = true
                case .cyber, .general: break
                }
            }
            if !include, !manual.isEmpty { include = manual.contains { NewsTopics.mentions(item, $0) } }
            guard include else { continue }
            // Ce qui vous concerne et n'est pas lu passe devant.
            if concerned && !read.contains(item.id) { mine.append(item) } else { rest.append(item) }
            if !read.contains(item.id) { d.unreadForYou += 1 }
        }
        d.forYou = mine + rest
        d.cyber = d.visible.filter { $0.category == .cyber && shown($0) }
        d.languages = d.visible.filter { $0.category == .langage || $0.category == .personnel }
        d.general = d.visible.filter { $0.category == .general }
        d.all = d.visible.filter(shown)
        d.favorites = state.items.filter { starred.contains($0.id) }
        let severe = d.visible.filter { confirmed($0) && $0.isSevere && !read.contains($0.id) }
        d.concerningSevere = severe.count
        d.topAlert = severe.max { a, b in (a.isCritical ? 1 : 0, a.date) < (b.isCritical ? 1 : 0, b.date) }
        derived = d
    }

    // MARK: Notifications

    /// Notification macOS seulement pour une alerte critique qui touche la machine (désactivable).
    private func notify(_ added: [NewsItem]) {
        let alerts = added.filter { item in
            confirmed(item) && !state.notified.contains(item.id)
                && ((item.isCritical && preferences.newsNotifications) || preferences.notifyNews)
        }
        state.notified.formUnion(added.map(\.id))
        guard !alerts.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let first = alerts[0]
        let match = matches[first.id]?.first
        let content = UNMutableNotificationContent()
        content.title = alerts.count == 1 ? (first.isCritical ? String(localized: "Faille critique qui vous concerne") : String(localized: "Une news vous concerne")) : String(localized: "\(alerts.count) avis vous concernent")
        content.body = first.title + (match.map { " · \($0.package) \($0.version ?? "") (\($0.project?.lastPathComponent ?? $0.place))" } ?? "")
        content.sound = .default
        let request = UNNotificationRequest(identifier: first.id, content: content, trigger: nil)
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    private func save() {
        let snapshot = state
        Task { try? await store.save(snapshot) }
    }
}

extension AppModel {
    /// Manifestes des projets et paquets installés, lus sur le disque (sans réseau).
    func newsInventory() async -> (manifests: [ProjectManifest], packages: [Package]) {
        let known = knownProjects
        let scanner = repoScanner
        let loaded = packages.packages
        let manifests = await Task.detached {
            let projects = known.isEmpty ? scanner.repositories() : known
            return projects.flatMap(DependencyReader.read)
        }.value
        if !loaded.isEmpty { return (manifests, loaded) }
        let runner = runner
        let scanned = await PackageScanner(runner: runner, checkRemote: false).scan().packages
        return (manifests, scanned)
    }

    /// Relit les manifestes et paquets seulement si quelque chose a changé depuis.
    func reloadNewsInventory(force: Bool = false) async {
        guard force || news.inventoryStale else { return }
        news.inventoryStale = false
        let inventory = await newsInventory()
        news.updateInventory(manifests: inventory.manifests, packages: inventory.packages)
    }
}

extension AppModel {
    /// Va là où l'on corrige ce qu'une news signale : le projet (onglet Sécurité) ou le paquet installé.
    func fix(_ match: NewsMatch) {
        if let project = match.project {
            securityFocus = match.package
            if analysis.stale && !analysis.loading { scanAnalysis() }
            openRepository(project, tab: .security)
        } else {
            packageFocus = match.package.split(separator: "@").first.map(String.init) ?? match.package
            switch match.source {
            case .runtimes: selection = .runtimes
            default:
                let outdated = packages.updates.contains { $0.identifier == match.package || $0.name == match.package }
                selection = outdated ? .majs : .inventaire
            }
        }
    }

    /// Libellé du bouton « Corriger » selon l'endroit visé.
    static func fixLabel(_ match: NewsMatch) -> String {
        if let project = match.project { return String(localized: "Corriger dans \(project.lastPathComponent) →") }
        return match.source == .runtimes ? String(localized: "Voir dans Runtimes →") : String(localized: "Voir dans Paquets →")
    }
}
