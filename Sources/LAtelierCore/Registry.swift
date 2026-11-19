import Foundation

/// Dernière version publiée d'une bibliothèque, et sa licence quand le registre la donne.
public struct RegistryInfo: Sendable, Codable, Hashable {
    public var latest: String?
    public var license: String?
    public var fetchedAt: Date

    public init(latest: String?, license: String? = nil, fetchedAt: Date = .now) {
        self.latest = latest
        self.license = license
        self.fetchedAt = fetchedAt
    }
}

/// Petit cache JSON sur disque (~/Library/Caches/local.latelier), pour ne pas tout redemander à chaque analyse.
public actor DiskCache<Value: Codable & Sendable> {
    private let file: URL
    private var values: [String: Value]?

    public init(name: String, directory: URL = DiskCache.defaultDirectory) {
        self.file = directory.appending(path: name)
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "local.latelier")
    }

    public func get(_ key: String) -> Value? {
        load()
        return values?[key]
    }

    public func set(_ entries: [String: Value]) {
        load()
        values?.merge(entries) { _, new in new }
        save()
    }

    public func clear() {
        values = [:]
        try? FileManager.default.removeItem(at: file)
    }

    private func load() {
        guard values == nil else { return }
        values = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Value].self, from: $0) } ?? [:]
    }

    private func save() {
        guard let values, let data = try? JSONEncoder().encode(values) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

/// Interroge les registres publics (npm, crates.io, PyPI, proxy Go, Packagist, Maven Central, RubyGems).
/// Seuls des noms de paquets sortent de la machine (règle n° 7).
public struct RegistryClient: Sendable {
    public var maxAge: TimeInterval
    public var cache: DiskCache<RegistryInfo>
    public var session: URLSession

    public init(maxAge: TimeInterval = 12 * 3600, cache: DiskCache<RegistryInfo> = DiskCache(name: "registry.json"), session: URLSession = .shared) {
        self.maxAge = maxAge
        self.cache = cache
        self.session = session
    }

    /// clé `Dependency.libraryKey` → info. 8 requêtes à la fois.
    public func latest(_ libraries: [(ecosystem: Ecosystem, name: String)], force: Bool = false) async -> [String: RegistryInfo] {
        var result: [String: RegistryInfo] = [:]
        var missing: [(Ecosystem, String)] = []
        for (ecosystem, name) in libraries {
            let key = "\(ecosystem.rawValue):\(name)"
            if !force, let cached = await cache.get(key), Date().timeIntervalSince(cached.fetchedAt) < maxAge {
                result[key] = cached
            } else {
                missing.append((ecosystem, name))
            }
        }
        let fetched = await withTaskGroup(of: (String, RegistryInfo?).self) { group in
            var iterator = missing.makeIterator()
            func next() -> Bool {
                guard let (ecosystem, name) = iterator.next() else { return false }
                group.addTask { ("\(ecosystem.rawValue):\(name)", await fetch(ecosystem, name)) }
                return true
            }
            for _ in 0..<8 where next() {}
            var found: [String: RegistryInfo] = [:]
            while let (key, info) = await group.next() {
                if let info { found[key] = info }
                _ = next()
            }
            return found
        }
        await cache.set(fetched)
        return result.merging(fetched) { _, new in new }
    }

    func fetch(_ ecosystem: Ecosystem, _ name: String) async -> RegistryInfo? {
        switch ecosystem {
        case .npm:
            let encoded = name.replacingOccurrences(of: "/", with: "%2F")
            guard let object = await json("https://registry.npmjs.org/\(encoded)/latest") as? [String: Any] else { return nil }
            return RegistryInfo(latest: object["version"] as? String, license: Self.license(object["license"]))
        case .cargo:
            // Index « sparse » : fichiers statiques sur CDN, sans limite de débit (contrairement à l'API).
            guard let text = await text("https://index.crates.io/\(Self.crateIndexPath(name))") else { return nil }
            let versions = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      object["yanked"] as? Bool != true, let version = object["vers"] as? String,
                      !version.contains("-") else { return nil }
                return version
            }
            return RegistryInfo(latest: versions.max { VersionOrder.compare($0, $1) == .orderedAscending })
        case .pypi:
            guard let object = await json("https://pypi.org/pypi/\(name)/json") as? [String: Any],
                  let info = object["info"] as? [String: Any] else { return nil }
            return RegistryInfo(latest: info["version"] as? String, license: Self.pythonLicense(info))
        case .go:
            guard let object = await json("https://proxy.golang.org/\(Self.goEscape(name))/@latest") as? [String: Any] else { return nil }
            return RegistryInfo(latest: object["Version"] as? String)
        case .packagist:
            guard let object = await json("https://repo.packagist.org/p2/\(name).json") as? [String: Any],
                  let versions = (object["packages"] as? [String: Any])?[name] as? [[String: Any]] else { return nil }
            let stable = versions.first { ($0["version"] as? String).map { !VersionOrder.isPrerelease($0) && !$0.contains("-") } ?? false }
            var latest = stable?["version"] as? String
            if latest?.hasPrefix("v") == true { latest?.removeFirst() }
            return RegistryInfo(latest: latest, license: (stable?["license"] as? [String])?.joined(separator: " / "))
        case .maven:
            let parts = name.split(separator: ":")
            guard parts.count == 2 else { return nil }
            let path = parts[0].replacingOccurrences(of: ".", with: "/") + "/" + parts[1]
            guard let xml = await text("https://repo1.maven.org/maven2/\(path)/maven-metadata.xml"),
                  let start = xml.range(of: "<release>"), let end = xml.range(of: "</release>") else { return nil }
            return RegistryInfo(latest: String(xml[start.upperBound..<end.lowerBound]))
        case .rubygems:
            guard let object = await json("https://rubygems.org/api/v1/versions/\(name)/latest.json") as? [String: Any] else { return nil }
            return RegistryInfo(latest: object["version"] as? String)
        case .swift:
            return nil   // pas de registre central : il faudrait interroger GitHub, ce qu'on évite
        }
    }

    // MARK: Réseau

    private func data(_ address: String) async -> Data? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("LAtelier (macOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private func json(_ address: String) async -> Any? {
        await data(address).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    private func text(_ address: String) async -> String? {
        await data(address).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: Formats

    /// Chemin dans l'index crates.io : « 1/a », « 2/ab », « 3/a/abc », « se/rd/serde ».
    static func crateIndexPath(_ name: String) -> String {
        let lower = name.lowercased()
        switch lower.count {
        case 1: return "1/\(lower)"
        case 2: return "2/\(lower)"
        case 3: return "3/\(lower.prefix(1))/\(lower)"
        default: return "\(lower.prefix(2))/\(lower.dropFirst(2).prefix(2))/\(lower)"
        }
    }

    /// Le proxy Go encode les majuscules : « github.com/BurntSushi/toml » → « github.com/!burnt!sushi/toml ».
    static func goEscape(_ module: String) -> String {
        module.map { $0.isUppercase ? "!\($0.lowercased())" : String($0) }.joined()
    }

    static func license(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let object = value as? [String: Any] { return object["type"] as? String }
        return nil
    }

    static func pythonLicense(_ info: [String: Any]) -> String? {
        if let expression = info["license_expression"] as? String, !expression.isEmpty { return expression }
        if let license = info["license"] as? String, !license.isEmpty, license.count <= 40, !license.contains("\n") { return license }
        let classifier = (info["classifiers"] as? [String])?.first { $0.hasPrefix("License :: OSI Approved :: ") }
        return classifier.map { String($0.dropFirst("License :: OSI Approved :: ".count)).replacingOccurrences(of: " License", with: "") }
    }
}
