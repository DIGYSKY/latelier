import Foundation

/// Une action passée, consultable dans l'Historique (règle de sécurité n° 5).
public struct HistoryEntry: Sendable, Codable, Identifiable, Hashable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case nettoyage, git, paquet, commande, systeme, processus, serveur

        public var label: String {
            switch self {
            case .nettoyage: "Nettoyage"
            case .git: "Git"
            case .paquet: "Paquets"
            case .commande: "Commandes"
            case .systeme: "Système"
            case .processus: "Processus"
            case .serveur: "Serveurs"
            }
        }
    }

    public enum Outcome: Sendable, Codable, Hashable {
        case success
        /// Une partie seulement a été faite (règle n° 6 : on le dit).
        case partial(String)
        case failure(String)
        case cancelled
    }

    public let id: UUID
    public let date: Date
    public var kind: Kind
    public var title: String
    public var summary: String
    public var commands: [CommandLog]
    public var outcome: Outcome
    public var bytesFreed: Int64?

    public init(
        id: UUID = UUID(), date: Date = Date(), kind: Kind, title: String, summary: String = "",
        commands: [CommandLog] = [], outcome: Outcome, bytesFreed: Int64? = nil
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.title = title
        self.summary = summary
        self.commands = commands
        self.outcome = outcome
        self.bytesFreed = bytesFreed
    }
}

public struct CommandLog: Sendable, Codable, Hashable {
    public var command: String
    public var exitStatus: Int32?
    /// Sortie combinée, tronquée au début si elle est trop longue.
    public var output: String
    public var duration: TimeInterval

    public init(command: String, exitStatus: Int32?, output: String, duration: TimeInterval) {
        self.command = command
        self.exitStatus = exitStatus
        self.output = output
        self.duration = duration
    }
}

/// Historique sur disque, en JSON, dans `~/Library/Application Support/local.latelier/`.
public actor HistoryStore {
    public let fileURL: URL
    private let limit: Int
    private var cache: [HistoryEntry]?

    public init(fileURL: URL = HistoryStore.defaultURL, limit: Int = 5_000) {
        self.fileURL = fileURL
        self.limit = limit
    }

    public static var defaultURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("history.json")
    }

    /// Les plus récentes d'abord.
    public func all() throws -> [HistoryEntry] {
        try load()
    }

    public func append(_ entry: HistoryEntry) throws {
        var entries = try load()
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        try save(entries)
    }

    /// Retire les entrées plus anciennes que `days` jours ; rend le nombre retiré.
    @discardableResult
    public func prune(olderThan days: Int, now: Date = .now) throws -> Int {
        let entries = try load()
        let limit = now.addingTimeInterval(-Double(days) * 86_400)
        let kept = entries.filter { $0.date >= limit }
        guard kept.count != entries.count else { return 0 }
        try save(kept)
        return entries.count - kept.count
    }

    public func clear() throws {
        try save([])
    }

    private func load() throws -> [HistoryEntry] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cache = []
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([HistoryEntry].self, from: Data(contentsOf: fileURL))
        cache = entries
        return entries
    }

    private func save(_ entries: [HistoryEntry]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
        cache = entries
    }
}

public enum AppPaths {
    public static let bundleIdentifier = "local.latelier"

    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }
}
