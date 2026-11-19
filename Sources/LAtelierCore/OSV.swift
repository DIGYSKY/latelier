import Foundation

/// Gravité d'une faille, d'après l'avis (GitHub) ou le score CVSS.
public enum Severity: Int, Sendable, Codable, CaseIterable, Comparable {
    case unknown, low, moderate, high, critical

    public var label: String {
        switch self {
        case .critical: "Critique"
        case .high: "Élevée"
        case .moderate: "Modérée"
        case .low: "Faible"
        case .unknown: "Non notée"
        }
    }

    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    init(text: String) {
        switch text.uppercased() {
        case "CRITICAL": self = .critical
        case "HIGH": self = .high
        case "MODERATE", "MEDIUM": self = .moderate
        case "LOW": self = .low
        default: self = .unknown
        }
    }

    init(score: Double) {
        switch score {
        case 9...: self = .critical
        case 7..<9: self = .high
        case 4..<7: self = .moderate
        case 0.1..<4: self = .low
        default: self = .unknown
        }
    }
}

/// Un avis OSV, réduit à ce qu'on affiche.
public struct Vulnerability: Sendable, Codable, Hashable, Identifiable {
    public struct Affected: Sendable, Codable, Hashable {
        public var ecosystem: String
        public var name: String
        /// Intervalles : suites d'événements « introduced » / « fixed » / « last_affected ».
        public var ranges: [[Event]]
    }

    public struct Event: Sendable, Codable, Hashable {
        public var introduced: String?
        public var fixed: String?
        public var lastAffected: String?
    }

    public var id: String
    public var aliases: [String]
    public var summary: String
    public var severity: Severity
    public var score: Double?
    public var published: Date?
    public var modified: String
    public var affected: [Affected]

    public var url: URL { URL(string: "https://osv.dev/vulnerability/\(id)")! }

    /// Identifiant le plus parlant : CVE si connu, sinon l'identifiant de l'avis.
    public var displayID: String { aliases.first { $0.hasPrefix("CVE-") } ?? id }

    /// Version qui corrige la faille pour la version installée (`nil` : pas encore de correctif).
    public func fixedVersion(for dependency: Dependency) -> String? {
        let pypi = dependency.ecosystem == .pypi
        func normalize(_ name: String) -> String { pypi ? PyProject.normalize(name) : name.lowercased() }
        let target = normalize(dependency.name)
        var candidates: [String] = []
        for entry in affected where entry.ecosystem == dependency.ecosystem.osvName && normalize(entry.name) == target {
            for events in entry.ranges {
                var introduced: String?
                for event in events {
                    if let value = event.introduced { introduced = value }
                    if let fixed = event.fixed {
                        candidates.append(fixed)
                        let afterStart = introduced == nil || introduced == "0"
                            || VersionOrder.compare(dependency.version, introduced!) != .orderedAscending
                        if afterStart && VersionOrder.compare(dependency.version, fixed) == .orderedAscending { return fixed }
                    }
                }
            }
        }
        return candidates
            .filter { VersionOrder.compare(dependency.version, $0) == .orderedAscending }
            .min { VersionOrder.compare($0, $1) == .orderedAscending }
    }

    // MARK: Lecture

    public static func parse(_ data: Data) -> Vulnerability? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String else { return nil }
        let summary = (object["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (object["details"] as? String).map { String($0.split(whereSeparator: \.isNewline).first ?? "").prefix(160).description }
            ?? id
        var severity = Severity.unknown
        var score: Double?
        if let text = (object["database_specific"] as? [String: Any])?["severity"] as? String { severity = Severity(text: text) }
        for entry in (object["severity"] as? [[String: Any]]) ?? [] {
            guard let vector = entry["score"] as? String, (entry["type"] as? String)?.hasPrefix("CVSS_V3") == true,
                  let value = CVSS3.baseScore(vector) else { continue }
            score = value
            if severity == .unknown { severity = Severity(score: value) }
        }
        var affected: [Affected] = []
        for entry in (object["affected"] as? [[String: Any]]) ?? [] {
            guard let package = entry["package"] as? [String: Any],
                  let ecosystem = package["ecosystem"] as? String, let name = package["name"] as? String else { continue }
            if severity == .unknown, let text = ((entry["database_specific"] ?? entry["ecosystem_specific"]) as? [String: Any])?["severity"] as? String {
                severity = Severity(text: text)
            }
            let ranges = ((entry["ranges"] as? [[String: Any]]) ?? []).filter { ($0["type"] as? String) != "GIT" }.map { range in
                ((range["events"] as? [[String: String]]) ?? []).map {
                    Event(introduced: $0["introduced"], fixed: $0["fixed"], lastAffected: $0["last_affected"])
                }
            }
            affected.append(Affected(ecosystem: ecosystem.split(separator: ":").first.map(String.init) ?? ecosystem, name: name, ranges: ranges))
        }
        let published = (object["published"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        return Vulnerability(
            id: id, aliases: object["aliases"] as? [String] ?? [], summary: summary.trimmingCharacters(in: .whitespaces),
            severity: severity, score: score, published: published, modified: object["modified"] as? String ?? "",
            affected: affected
        )
    }

    /// Un même problème publié par plusieurs bases (PYSEC + GHSA) : on garde un seul avis, le mieux renseigné.
    public static func deduplicated(_ vulns: [Vulnerability]) -> [Vulnerability] {
        let ranked = vulns.sorted { a, b in
            (a.id.hasPrefix("GHSA") ? 1 : 0, a.severity.rawValue, a.id) > (b.id.hasPrefix("GHSA") ? 1 : 0, b.severity.rawValue, b.id)
        }
        var kept: [Vulnerability] = []
        for vuln in ranked {
            let names = Set([vuln.id] + vuln.aliases)
            if kept.contains(where: { !names.isDisjoint(with: [$0.id] + $0.aliases) }) { continue }
            kept.append(vuln)
        }
        return kept
    }
}

/// Score de base CVSS 3.x calculé depuis le vecteur (« CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H » → 9,8).
public enum CVSS3 {
    public static func baseScore(_ vector: String) -> Double? {
        var metrics: [String: String] = [:]
        for part in vector.split(separator: "/") {
            let pair = part.split(separator: ":")
            if pair.count == 2 { metrics[String(pair[0])] = String(pair[1]) }
        }
        let changed = metrics["S"] == "C"
        guard let av = ["N": 0.85, "A": 0.62, "L": 0.55, "P": 0.2][metrics["AV"] ?? ""],
              let ac = ["L": 0.77, "H": 0.44][metrics["AC"] ?? ""],
              let pr = (changed ? ["N": 0.85, "L": 0.68, "H": 0.5] : ["N": 0.85, "L": 0.62, "H": 0.27])[metrics["PR"] ?? ""],
              let ui = ["N": 0.85, "R": 0.62][metrics["UI"] ?? ""] else { return nil }
        let cia = ["H": 0.56, "L": 0.22, "N": 0.0]
        guard let c = cia[metrics["C"] ?? ""], let i = cia[metrics["I"] ?? ""], let a = cia[metrics["A"] ?? ""] else { return nil }
        let iss = 1 - (1 - c) * (1 - i) * (1 - a)
        let impact = changed ? 7.52 * (iss - 0.029) - 3.25 * pow(iss - 0.02, 15) : 6.42 * iss
        guard impact > 0 else { return 0 }
        let exploitability = 8.22 * av * ac * pr * ui
        return roundUp(min(changed ? 1.08 * (impact + exploitability) : impact + exploitability, 10))
    }

    private static func roundUp(_ value: Double) -> Double {
        let scaled = Int((value * 100_000).rounded())
        return scaled % 10_000 == 0 ? Double(scaled) / 100_000 : Double(scaled / 10_000 + 1) / 10
    }
}

/// Client OSV.dev : requêtes groupées (noms et versions seulement), avis mis en cache.
public struct OSVClient: Sendable {
    public enum Failure: Error, LocalizedError {
        case unreachable(String)
        public var errorDescription: String? {
            switch self { case .unreachable(let reason): "OSV.dev injoignable : \(reason)" }
        }
    }

    public var session: URLSession
    public var cache: DiskCache<Vulnerability>

    public init(session: URLSession = .shared, cache: DiskCache<Vulnerability> = DiskCache(name: "osv.json")) {
        self.session = session
        self.cache = cache
    }

    /// Failles connues pour chaque `Dependency.versionKey`.
    public func vulnerabilities(of dependencies: [Dependency]) async throws -> [String: [Vulnerability]] {
        var unique: [String: Dependency] = [:]
        for dep in dependencies where !dep.version.isEmpty { unique[dep.versionKey] = dep }
        let list = Array(unique.values)
        // Lots de 1000 (limite de l'API), 4 requêtes à la fois.
        let chunks = stride(from: 0, to: list.count, by: 1000).map { Array(list[$0..<min($0 + 1000, list.count)]) }
        var ids: [String: [(id: String, modified: String)]] = [:]
        try await withThrowingTaskGroup(of: [(String, [(id: String, modified: String)])].self) { group in
            var iterator = chunks.makeIterator()
            func next() -> Bool {
                guard let chunk = iterator.next() else { return false }
                group.addTask {
                    let found = try await queryBatch(chunk)
                    return zip(chunk, found).filter { !$0.1.isEmpty }.map { ($0.0.versionKey, $0.1) }
                }
                return true
            }
            for _ in 0..<4 where next() {}
            while let pairs = try await group.next() {
                for (key, refs) in pairs { ids[key] = refs }
                _ = next()
            }
        }
        let wanted = Dictionary(ids.values.flatMap { $0 }.map { ($0.id, $0.modified) }, uniquingKeysWith: { a, _ in a })
        let details = await self.details(wanted)
        return ids.mapValues { refs in Vulnerability.deduplicated(refs.compactMap { details[$0.id] }) }
    }

    private func queryBatch(_ chunk: [Dependency]) async throws -> [[(id: String, modified: String)]] {
        let queries: [[String: Any]] = chunk.map { dep in
            ["version": Self.queryVersion(dep), "package": ["name": dep.name, "ecosystem": dep.ecosystem.osvName]]
        }
        var request = URLRequest(url: URL(string: "https://api.osv.dev/v1/querybatch")!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["queries": queries])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else {
            throw Failure.unreachable("réponse inattendue (code \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        return results.map { result in
            ((result["vulns"] as? [[String: Any]]) ?? []).compactMap { vuln in
                (vuln["id"] as? String).map { ($0, vuln["modified"] as? String ?? "") }
            }
        }
    }

    /// Les versions Go s'écrivent avec « v » dans go.mod, sans chez OSV ; PHP pareil.
    static func queryVersion(_ dep: Dependency) -> String {
        dep.version.hasPrefix("v") ? String(dep.version.dropFirst()) : dep.version
    }

    private func details(_ wanted: [String: String]) async -> [String: Vulnerability] {
        var result: [String: Vulnerability] = [:]
        var missing: [String] = []
        for (id, modified) in wanted {
            // querybatch donne les microsecondes, la fiche les nanosecondes : on compare à la seconde.
            if let cached = await cache.get(id), cached.modified.prefix(19) == modified.prefix(19) || modified.isEmpty {
                result[id] = cached
            } else {
                missing.append(id)
            }
        }
        let fetched = await withTaskGroup(of: Vulnerability?.self) { group in
            var iterator = missing.makeIterator()
            func next() -> Bool {
                guard let id = iterator.next(), let url = URL(string: "https://api.osv.dev/v1/vulns/\(id)") else { return false }
                group.addTask {
                    guard let (data, _) = try? await session.data(for: URLRequest(url: url, timeoutInterval: 20)) else { return nil }
                    return Vulnerability.parse(data)
                }
                return true
            }
            for _ in 0..<8 where next() {}
            var found: [String: Vulnerability] = [:]
            while let vuln = await group.next() {
                if let vuln { found[vuln.id] = vuln }
                _ = next()
            }
            return found
        }
        await cache.set(fetched)
        return result.merging(fetched) { _, new in new }
    }
}
