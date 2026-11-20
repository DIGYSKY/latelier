import Foundation

/// Une ligne de nettoyage : un ou plusieurs éléments du disque présentés ensemble.
public struct CleanupItem: Sendable, Identifiable, Hashable {
    public struct Entry: Sendable, Hashable {
        public let url: URL
        public let bytes: Int64
        /// Pour les filtres (« node_modules », « target »…).
        public let kind: String?

        public init(url: URL, bytes: Int64, kind: String? = nil) {
            self.url = url
            self.bytes = bytes
            self.kind = kind
        }
    }

    public enum Action: Sendable, Hashable {
        /// Retirer les entrées (corbeille ou définitif).
        case remove
        /// Vider la corbeille de macOS (via le Finder).
        case emptyTrash
        /// Commande officielle de l'outil (`npm cache clean --force`, `docker image prune -a`).
        /// Les entrées servent seulement à mesurer.
        case commands([CommandSpec])
    }

    public let id: String
    public var name: String
    public var detail: String
    public var detailIsPath: Bool
    public var meta: String?
    /// Méta en orange (ancienneté, « Définitif »).
    public var metaHighlighted: Bool
    public var tag: String?
    public var risk: Risk
    /// Non nul : la ligne est verrouillée, avec la raison.
    public var lockReason: String?
    public var selectedByDefault: Bool
    public var entries: [Entry]
    public var action: Action
    /// Taille affichée quand elle ne vient pas des entrées (corbeille).
    public var displayBytes: Int64?

    public init(
        id: String, name: String, detail: String, detailIsPath: Bool = false, meta: String? = nil,
        metaHighlighted: Bool = false, tag: String? = nil, risk: Risk = .safe, lockReason: String? = nil,
        selectedByDefault: Bool = true, entries: [Entry], action: Action = .remove, displayBytes: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.detailIsPath = detailIsPath
        self.meta = meta
        self.metaHighlighted = metaHighlighted
        self.tag = tag
        self.risk = risk
        self.lockReason = lockReason
        self.selectedByDefault = selectedByDefault
        self.entries = entries
        self.action = action
        self.displayBytes = displayBytes
    }

    public var bytes: Int64 { displayBytes ?? entries.reduce(0) { $0 + $1.bytes } }
    public var isLocked: Bool { lockReason != nil }
    public var kinds: Set<String> { Set(entries.compactMap(\.kind)) }

    /// La même ligne, limitée à un type d'artefact.
    public func filtered(kind: String?) -> CleanupItem? {
        guard let kind else { return self }
        var copy = self
        copy.entries = entries.filter { $0.kind == kind }
        return copy.entries.isEmpty ? nil : copy
    }
}

public struct CleanupGroup: Sendable, Identifiable, Hashable {
    public enum Tone: Sendable, Hashable { case normal, neutral, data }

    public let id: String
    public var title: String
    public var detail: String?
    public var tone: Tone
    public var items: [CleanupItem]

    public init(id: String, title: String, detail: String? = nil, tone: Tone = .normal, items: [CleanupItem]) {
        self.id = id
        self.title = title
        self.detail = detail
        self.tone = tone
        self.items = items
    }

    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

/// Transforme une sélection en plan à montrer en aperçu.
public enum CleanupPlanner {
    public static func plan(
        title: String, items: [CleanupItem], skipped: [CleanupItem] = [], summary: String? = nil
    ) -> ActionPlan? {
        let removable = items.filter { !$0.isLocked }
        guard !removable.isEmpty else { return nil }

        var steps: [ActionStep] = removable
            .filter { $0.action == .remove }
            .flatMap { $0.entries.map { ActionStep.remove($0.url, bytes: $0.bytes, permanently: false) } }
        for item in removable {
            if case .commands(let specs) = item.action { steps += specs.map(ActionStep.command) }
        }
        let emptiesTrash = removable.contains { $0.action == .emptyTrash }
        if emptiesTrash {
            steps.append(.command(CommandSpec("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"])))
        }
        let usesCommands = steps.contains(where: \.isCommandLike)
        let bytes = removable.reduce(Int64(0)) { $0 + $1.bytes }
        let summary = summary ?? (emptiesTrash
            ? String(localized: "La corbeille de macOS sera vidée définitivement.")
            : usesCommands
            ? String(localized: "Nettoyé avec la commande officielle de chaque outil : ce qui est supprimé ainsi ne passe pas par la corbeille.")
            : String(localized: "Seuls des fichiers recréables sont concernés. Le code source n’est jamais touché."))
        return ActionPlan(
            title: title,
            summary: summary,
            kind: .nettoyage,
            risk: removable.map(\.risk).max() ?? .safe,
            reversible: !emptiesTrash && !usesCommands,
            steps: steps,
            estimatedBytes: bytes,
            skipped: skipped.map { "\($0.name) : \($0.lockReason ?? String(localized: "ignoré"))" }
        )
    }
}

/// Taille réelle sur disque d'un fichier ou d'un dossier, sans suivre les liens.
public enum DiskUsage {
    public struct Result: Sendable {
        public var bytes: Int64
        public var files: Int
    }

    public static func measure(_ url: URL) -> Result {
        measure(url, skipping: [])
    }

    /// Mesure sans entrer dans les dossiers `skipping` (chemins absolus) : dossiers protégés par macOS.
    public static func measure(_ url: URL, skipping: Set<String>) -> Result {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return Result(bytes: 0, files: 0) }
        if values.isDirectory != true || values.isSymbolicLink == true {
            return Result(bytes: Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0), files: 1)
        }
        var result = Result(bytes: 0, files: 0)
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return result }
        var counter = 0
        for case let child as URL in enumerator {
            counter += 1
            if counter % 2048 == 0, Task.isCancelled { break }
            if !skipping.isEmpty, skipping.contains(child.path) || ["photoslibrary", "musiclibrary", "tvlibrary", "photolibrary"].contains(child.pathExtension) {
                enumerator.skipDescendants()
                continue
            }
            guard let v = try? child.resourceValues(forKeys: Set(keys)), v.isDirectory != true else { continue }
            result.bytes += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            result.files += 1
        }
        return result
    }

    /// Mesure plusieurs éléments en parallèle (8 à la fois).
    public static func measure(_ urls: [URL], skipping: Set<String>) async -> [URL: Result] {
        await withTaskGroup(of: (URL, Result).self) { group in
            var results: [URL: Result] = [:]
            var iterator = urls.makeIterator()
            for _ in 0..<8 {
                guard let url = iterator.next() else { break }
                group.addTask { (url, measure(url, skipping: skipping)) }
            }
            while let (url, result) = await group.next() {
                results[url] = result
                if let next = iterator.next() { group.addTask { (next, measure(next, skipping: skipping)) } }
            }
            return results
        }
    }

    public static func measure(_ urls: [URL]) async -> [URL: Result] {
        await withTaskGroup(of: (URL, Result).self) { group in
            var results: [URL: Result] = [:]
            var iterator = urls.makeIterator()
            for _ in 0..<8 {
                guard let url = iterator.next() else { break }
                group.addTask { (url, measure(url)) }
            }
            while let (url, result) = await group.next() {
                results[url] = result
                if let next = iterator.next() { group.addTask { (next, measure(next)) } }
            }
            return results
        }
    }
}

public enum RelativeDate {
    /// « il y a 14 mois », « aujourd’hui », « hier ».
    public static func french(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar(identifier: .gregorian)
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "aujourd’hui") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "hier")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale.current
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

extension URL {
    /// Chemin avec `~` pour le dossier personnel.
    public func abbreviatingHome(_ home: String = NSHomeDirectory()) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
