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
                if !refreshing, state.lastRefresh.map({ Date().timeIntervalSince($0) >= interval }) ?? true {
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
        recomputeMatches()
    }

    private func recomputeMatches() {
        var result: [String: [NewsMatch]] = [:]
        for item in state.items {
            let found = NewsMatcher.matches(item, in: inventory)
            if !found.isEmpty { result[item.id] = found }
        }
        matches = result
    }

    // MARK: Sources

    var sources: [NewsSource] { state.custom + NewsCatalog.builtIn }

    var followed: [NewsTopic] {
        autoTopics.filter { !state.hiddenTopics.contains($0.name) } + state.manualTopics.map { NewsTopic(name: $0, auto: false) }
    }

    private var followedNames: Set<String> { Set(followed.map(\.name)) }

    func isEnabled(_ source: NewsSource) -> Bool {
        state.overrides[source.id] ?? NewsCatalog.enabledByDefault(source, topics: followedNames)
    }

    var enabledSources: [NewsSource] { sources.filter(isEnabled) }

    func setEnabled(_ source: NewsSource, _ on: Bool) {
        state.overrides[source.id] = on
        save()
        // Une source activée est lue tout de suite si elle n'a jamais été lue.
        if on, state.status[source.id]?.lastSuccess == nil { Task { await refresh(only: [source]) } }
    }

    func source(_ id: String) -> NewsSource? { sources.first { $0.id == id } }

    /// Vérifie que l'adresse donne un flux RSS ou Atom, puis l'ajoute.
    func addSource(_ address: String) async -> String? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), url.host != nil else {
            return "Adresse invalide."
        }
        guard !sources.contains(where: { $0.url == url }) else { return "Ce flux est déjà dans la liste." }
        do {
            let feed = try await fetcher.probe(url)
            let id = "custom-" + UUID().uuidString.prefix(8).lowercased()
            let source = NewsSource(id: id, name: feed.title ?? url.host ?? "Flux", url: url, category: .personnel, builtIn: false)
            state.custom.insert(source, at: 0)
            await refresh(only: [source])
            return nil
        } catch {
            return "Lecture impossible : \(error.localizedDescription)"
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
        save()
    }

    func removeTopic(_ topic: NewsTopic) {
        if topic.auto { state.hiddenTopics.insert(topic.name) } else { state.manualTopics.removeAll { $0 == topic.name } }
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
        recomputeMatches()
        let failed = outcomes.filter { $0.error != nil && $0.items.isEmpty }.count
        message = failed > 0 ? "\(failed) source\(failed > 1 ? "s" : "") en erreur : voir Sources." : nil
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
        save()
    }

    func markUnread(_ item: NewsItem) {
        guard state.read.remove(item.id) != nil else { return }
        save()
    }

    func markAllRead(_ items: [NewsItem]) {
        state.read.formUnion(items.map(\.id))
        save()
    }

    func toggleStar(_ item: NewsItem) {
        if state.starred.remove(item.id) == nil { state.starred.insert(item.id) }
        save()
    }

    // MARK: Filtres

    /// Articles des sources actives (et favoris d'une source retirée).
    var visibleItems: [NewsItem] {
        let enabled = Set(enabledSources.map(\.id))
        return state.items.filter { enabled.contains($0.sourceID) || state.starred.contains($0.id) }
    }

    /// Un avis GitHub sans lien avec la machine n'est montré que s'il est critique ou élevé.
    private func isShown(_ item: NewsItem) -> Bool {
        item.sourceID != "gha" || item.isSevere || matches[item.id] != nil
    }

    func concerns(_ item: NewsItem) -> Bool { matches[item.id] != nil }
    func confirmed(_ item: NewsItem) -> Bool { matches[item.id]?.contains(where: \.confirmed) == true }

    /// Pour vous : ce qui touche la machine, les langages suivis et les sujets ajoutés à la main.
    /// Les autres avis de sécurité restent dans Cybersécurité.
    var forYou: [NewsItem] {
        let topics = followedNames
        let manual = state.manualTopics
        return visibleItems.filter { item in
            if concerns(item) { return true }
            switch item.category {
            case .langage: if let language = item.language, topics.contains(language) { return true }
            case .personnel: return true
            case .cyber, .general: break
            }
            return manual.contains { NewsTopics.mentions(item, $0) }
        }
        // Ce qui vous concerne et n'est pas lu passe devant.
        .sorted { a, b in
            let x = concerns(a) && !isRead(a), y = concerns(b) && !isRead(b)
            return x != y ? x : a.date > b.date
        }
    }

    var cyber: [NewsItem] { visibleItems.filter { $0.category == .cyber && isShown($0) } }
    var languages: [NewsItem] { visibleItems.filter { $0.category == .langage || $0.category == .personnel } }
    var general: [NewsItem] { visibleItems.filter { $0.category == .general } }
    var all: [NewsItem] { visibleItems.filter(isShown) }
    var favorites: [NewsItem] { state.items.filter { state.starred.contains($0.id) } }

    /// Non lues de « Pour vous » : la pastille de la barre latérale.
    var unreadForYou: Int { forYou.filter { !isRead($0) }.count }

    /// L'alerte la plus grave qui touche la machine (bandeau rouge).
    var topAlert: NewsItem? {
        visibleItems
            .filter { confirmed($0) && $0.isSevere && !isRead($0) }
            .max { a, b in (a.isCritical ? 1 : 0, a.date) < (b.isCritical ? 1 : 0, b.date) }
    }

    // MARK: Notifications

    /// Notification macOS seulement pour une alerte critique qui touche la machine (désactivable).
    private func notify(_ added: [NewsItem]) {
        let alerts = added.filter { $0.isCritical && confirmed($0) && !state.notified.contains($0.id) }
        state.notified.formUnion(added.map(\.id))
        guard preferences.newsNotifications, !alerts.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let first = alerts[0]
        let match = matches[first.id]?.first
        let content = UNMutableNotificationContent()
        content.title = alerts.count == 1 ? "Faille critique qui vous concerne" : "\(alerts.count) failles critiques vous concernent"
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
        let roots = projectRoots
        let loaded = packages.packages
        let manifests = await Task.detached {
            let projects = known.isEmpty ? RepoScanner(roots: roots).repositories() : known
            return projects.flatMap(DependencyReader.read)
        }.value
        if !loaded.isEmpty { return (manifests, loaded) }
        let runner = runner
        let scanned = await PackageScanner(runner: runner, checkRemote: false).scan().packages
        return (manifests, scanned)
    }

    func reloadNewsInventory() async {
        let inventory = await newsInventory()
        news.updateInventory(manifests: inventory.manifests, packages: inventory.packages)
    }
}
