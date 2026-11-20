import Foundation

/// Stockage › Docker : lu avec `docker system df -v`, nettoyé avec la CLI Docker.
public struct DockerReport: Sendable {
    public enum State: Sendable, Equatable {
        case notInstalled
        /// La CLI est là mais le moteur ne répond pas (Docker Desktop fermé) : on ne le démarre pas.
        case notRunning(String)
        case ready
    }

    public struct Image: Sendable, Hashable {
        public var name: String
        public var bytes: Int64
        public var containers: Int
    }

    public struct Container: Sendable, Hashable {
        public var name: String
        public var image: String
        public var running: Bool
        public var status: String
        public var bytes: Int64
        public var project: String?
    }

    public struct Volume: Sendable, Hashable {
        public var name: String
        public var bytes: Int64
        public var links: Int
        public var project: String?
        /// Nom du volume dans le compose (`postgres-data`).
        public var composeName: String?
    }

    public var state: State
    public var images: [Image] = []
    public var containers: [Container] = []
    public var volumes: [Volume] = []
    public var buildCache: Int64 = 0

    public init(state: State) {
        self.state = state
    }

    public var imageBytes: Int64 { images.reduce(0) { $0 + $1.bytes } }
    public var stoppedBytes: Int64 { containers.filter { !$0.running }.reduce(0) { $0 + $1.bytes } }
    public var volumeBytes: Int64 { volumes.reduce(0) { $0 + $1.bytes } }
    public var runningCount: Int { containers.filter(\.running).count }
}

public enum DockerVolumeKind: Sendable, Equatable {
    /// Base de données ou données applicatives : jamais coché par défaut.
    case data
    /// Recréable (node_modules, target, caches) ou anonyme.
    case cache
    case unknown

    public static func classify(_ volume: DockerReport.Volume) -> DockerVolumeKind {
        let name = (volume.composeName ?? volume.name).lowercased()
        let dataWords = ["postgres", "pg", "mysql", "mariadb", "mongo", "redis", "db", "data", "elastic", "opensearch",
                         "clickhouse", "timescale", "minio", "rabbit", "kafka", "zookeeper", "sqlite", "neo4j", "cassandra",
                         "influx", "grafana", "prometheus", "storage", "uploads", "media"]
        let cacheWords = ["cache", "node_modules", "node-modules", "target", "build", "dist", "tmp", "temp", "venv",
                          "gradle", "m2", "cargo", "pip", "npm", "pnpm", "yarn", "go-mod", "gomod", "vendor"]
        let words = Set(name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let joined = name
        if dataWords.contains(where: { words.contains($0) || joined.contains($0 + "_data") || joined.contains($0 + "-data") }) {
            return .data
        }
        if cacheWords.contains(where: { words.contains($0) || joined.contains($0) && $0.count >= 5 }) || joined == "node_modules" {
            return .cache
        }
        // Volume anonyme : 64 caractères hexadécimaux.
        if volume.name.count == 64, volume.name.allSatisfy(\.isHexDigit) { return .cache }
        return .unknown
    }
}

public enum DockerScanner {
    /// Tailles de Docker : « 1.112GB », « 32.77kB », « 0B » (puissances de 1000).
    public static func bytes(_ text: String) -> Int64 {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let number = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number) else { return 0 }
        let unit = trimmed.dropFirst(number.count).uppercased()
        let factor: Double = switch unit {
        case "KB": 1e3
        case "MB": 1e6
        case "GB": 1e9
        case "TB": 1e12
        default: 1
        }
        return Int64(value * factor)
    }

    static func labels(_ text: String?) -> [String: String] {
        var result: [String: String] = [:]
        for pair in (text ?? "").split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
        return result
    }

    /// Sortie de `docker system df -v --format '{{json .}}'`.
    public static func parse(_ data: Data) -> DockerReport? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var report = DockerReport(state: .ready)
        for image in object["Images"] as? [[String: Any]] ?? [] {
            let repository = image["Repository"] as? String ?? "<none>"
            let tag = image["Tag"] as? String ?? ""
            let name = repository == "<none>" ? "image sans nom" : (tag.isEmpty || tag == "<none>" ? repository : "\(repository):\(tag)")
            let unique = bytes(image["UniqueSize"] as? String ?? image["Size"] as? String ?? "0B")
            report.images.append(.init(name: name, bytes: unique, containers: Int(image["Containers"] as? String ?? "") ?? 0))
        }
        for container in object["Containers"] as? [[String: Any]] ?? [] {
            let labels = labels(container["Labels"] as? String)
            report.containers.append(.init(
                name: container["Names"] as? String ?? "?", image: container["Image"] as? String ?? "",
                running: (container["State"] as? String) == "running", status: container["Status"] as? String ?? "",
                bytes: bytes((container["Size"] as? String ?? "0B").components(separatedBy: " ").first ?? "0B"),
                project: labels["com.docker.compose.project"]
            ))
        }
        for volume in object["Volumes"] as? [[String: Any]] ?? [] {
            let labels = labels(volume["Labels"] as? String)
            report.volumes.append(.init(
                name: volume["Name"] as? String ?? "?", bytes: bytes(volume["Size"] as? String ?? "0B"),
                links: Int(volume["Links"] as? String ?? "") ?? 0,
                project: labels["com.docker.compose.project"], composeName: labels["com.docker.compose.volume"]
            ))
        }
        for entry in object["BuildCache"] as? [[String: Any]] ?? [] where (entry["InUse"] as? String) != "true" && (entry["InUse"] as? Bool) != true {
            report.buildCache += bytes(entry["Size"] as? String ?? "0B")
        }
        return report
    }

    public static func scan(runner: CommandRunner) async -> DockerReport {
        guard let docker = runner.locator.locate("docker") else { return DockerReport(state: .notInstalled) }
        do {
            let result = try await runner.run(CommandSpec(docker.path, ["system", "df", "-v", "--format", "{{json .}}"]), timeout: .seconds(60))
            guard result.succeeded, let report = parse(Data(result.stdout.joined(separator: "\n").utf8)) else {
                let message = result.stderr.first { !$0.isEmpty } ?? "Le moteur Docker ne répond pas."
                return DockerReport(state: .notRunning(message))
            }
            return report
        } catch {
            return DockerReport(state: .notRunning(error.localizedDescription))
        }
    }

    /// Lignes à nettoyer. Les commandes passent par la CLI : ce que Docker supprime ne va pas à la corbeille.
    public static func groups(_ report: DockerReport, docker: String) -> [CleanupGroup] {
        guard report.state == .ready else { return [] }
        var safe: [CleanupItem] = []
        let unused = report.images.filter { $0.containers == 0 }
        if !unused.isEmpty {
            let names = unused.sorted { $0.bytes > $1.bytes }.prefix(4).map(\.name).joined(separator: ", ")
            safe.append(CleanupItem(
                id: "docker:images", name: "Images inutilisées",
                detail: "\(unused.count) image\(unused.count > 1 ? "s" : "") sans conteneur · \(names)\(unused.count > 4 ? "…" : "")",
                meta: "docker image prune -a",
                entries: [], action: .commands([CommandSpec(docker, ["image", "prune", "-a", "-f"])]),
                displayBytes: unused.reduce(0) { $0 + $1.bytes }
            ))
        }
        if report.buildCache > 0 {
            safe.append(CleanupItem(
                id: "docker:build", name: "Build cache", detail: "BuildKit, recréé au prochain build", meta: "docker builder prune",
                entries: [], action: .commands([CommandSpec(docker, ["builder", "prune", "-f"])]), displayBytes: report.buildCache
            ))
        }
        let stopped = report.containers.filter { !$0.running }
        if !stopped.isEmpty {
            safe.append(CleanupItem(
                id: "docker:containers", name: "Conteneurs arrêtés",
                detail: "\(stopped.count) conteneur\(stopped.count > 1 ? "s" : "") · " + stopped.prefix(4).map(\.name).joined(separator: ", "),
                meta: "docker container prune",
                entries: [], action: .commands([CommandSpec(docker, ["container", "prune", "-f"])]),
                displayBytes: stopped.reduce(0) { $0 + $1.bytes }
            ))
        }
        var data: [CleanupItem] = []
        var review: [CleanupItem] = []
        for volume in report.volumes.sorted(by: { $0.bytes > $1.bytes }) {
            let kind = DockerVolumeKind.classify(volume)
            let project = volume.project.map { "projet \($0)" }
            let remove = CleanupItem.Action.commands([CommandSpec(docker, ["volume", "rm", volume.name])])
            if volume.links > 0 {
                safe.append(CleanupItem(
                    id: "docker:volume:\(volume.name)", name: volume.name,
                    detail: "Ignoré : utilisé par \(volume.links) conteneur\(volume.links > 1 ? "s" : "")", meta: "—",
                    tag: "Utilisé", risk: .protected, lockReason: "volume utilisé par un conteneur", selectedByDefault: false,
                    entries: [], action: remove, displayBytes: volume.bytes
                ))
                continue
            }
            switch kind {
            case .cache:
                safe.append(CleanupItem(
                    id: "docker:volume:\(volume.name)", name: volume.name,
                    detail: ["Volume de cache, recréable", project].compactMap { $0 }.joined(separator: " · "),
                    detailIsPath: false, meta: "aucun conteneur", entries: [], action: remove, displayBytes: volume.bytes
                ))
            case .data:
                data.append(CleanupItem(
                    id: "docker:volume:\(volume.name)", name: volume.name,
                    detail: ["Données (base de données ou fichiers)", project].compactMap { $0 }.joined(separator: " · "),
                    meta: "Orphelin", metaHighlighted: true, risk: .danger, selectedByDefault: false,
                    entries: [], action: remove, displayBytes: volume.bytes
                ))
            case .unknown:
                review.append(CleanupItem(
                    id: "docker:volume:\(volume.name)", name: volume.name,
                    detail: ["Contenu inconnu", project].compactMap { $0 }.joined(separator: " · "),
                    meta: "aucun conteneur", risk: .caution, selectedByDefault: false,
                    entries: [], action: remove, displayBytes: volume.bytes
                ))
            }
        }
        for container in report.containers where container.running {
            safe.append(CleanupItem(
                id: "docker:running:\(container.name)", name: "\(container.name) (en cours)",
                detail: "Ignoré : conteneur en cours d’exécution · \(container.image)", meta: "—", tag: "Actif",
                risk: .protected, lockReason: "conteneur en cours d’exécution", selectedByDefault: false,
                entries: [], action: .remove, displayBytes: container.bytes
            ))
        }
        var groups: [CleanupGroup] = []
        if !safe.isEmpty {
            groups.append(CleanupGroup(id: "docker-safe", title: "Sans risque · recréable",
                                       detail: "Images, conteneurs arrêtés, build cache, volumes de cache", items: safe))
        }
        if !review.isEmpty {
            groups.append(CleanupGroup(id: "docker-review", title: "À vérifier", detail: "Volumes sans conteneur dont le contenu n’est pas reconnu",
                                       tone: .neutral, items: review))
        }
        if !data.isEmpty {
            groups.append(CleanupGroup(id: "docker-data", title: "Données · jamais cochées par défaut",
                                       detail: "Volumes de bases de données : leur suppression efface définitivement les données",
                                       tone: .data, items: data))
        }
        return groups
    }
}
