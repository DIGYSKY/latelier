import Foundation

/// Un paquet qui en demande un autre : « express 4.21.2 demande proxy-addr ~2.0.7 ».
public struct DependencyRequirement: Sendable, Hashable, Codable {
    public var parent: String
    public var parentVersion: String
    /// Intervalle demandé par le parent ; `nil` si le lockfile ne le donne pas (pnpm).
    public var range: String?

    public init(parent: String, parentVersion: String, range: String?) {
        self.parent = parent
        self.parentVersion = parentVersion
        self.range = range
    }

    /// « express 4.21.2 (~2.0.7) »
    public var label: String {
        "\(parent) \(parentVersion)" + (range.map { " (\($0))" } ?? "")
    }
}

// MARK: - Intervalles npm

/// Sous-ensemble de node-semver : `^`, `~`, comparateurs, `x`, `*`, `a - b`, `||`.
public enum SemverRange {
    /// `nil` : intervalle non reconnu (alias, URL, tag « latest »…).
    public static func satisfies(_ version: String, _ range: String) -> Bool? {
        var text = range.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("npm:") {
            // « npm:^1.2.0 » (Yarn Berry) ; « npm:autre@1.0 » est un alias : non reconnu.
            text = String(text.dropFirst(4))
            if text.contains("@") { return nil }
        }
        guard parts(version) != nil else { return nil }
        var any = false
        for alternative in text.components(separatedBy: "||") {
            guard let set = comparators(alternative.trimmingCharacters(in: .whitespaces)) else { return nil }
            if set.allSatisfy({ $0(version) }) { any = true }
        }
        return any
    }

    private typealias Check = (String) -> Bool

    private static func comparators(_ text: String) -> [Check]? {
        if text.isEmpty || text == "*" || text == "x" || text == "X" { return [] }
        // « 1.2.3 - 2.3.4 »
        let hyphen = text.components(separatedBy: " - ")
        if hyphen.count == 2 {
            guard let low = bounds(hyphen[0].trimmingCharacters(in: .whitespaces)),
                  let high = bounds(hyphen[1].trimmingCharacters(in: .whitespaces)) else { return nil }
            let top = high.low
            return [atLeast(low.low), high.high.map(below) ?? { VersionOrder.compare($0, top) != .orderedDescending }]
        }
        // « >= 1.2 » : l'opérateur peut être séparé de la version.
        var tokens: [String] = []
        for token in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            if let last = tokens.last, [">", ">=", "<", "<=", "=", "^", "~"].contains(last) {
                tokens[tokens.count - 1] = last + token
            } else {
                tokens.append(token)
            }
        }
        var result: [Check] = []
        for token in tokens {
            guard let checks = comparator(token) else { return nil }
            result += checks
        }
        return result
    }

    private static func comparator(_ raw: String) -> [Check]? {
        var token = raw
        var op = ""
        for candidate in [">=", "<=", ">", "<", "=", "^", "~>", "~"] where token.hasPrefix(candidate) {
            op = candidate
            token.removeFirst(candidate.count)
            break
        }
        if token.hasPrefix("v") { token.removeFirst() }
        if token.isEmpty || token == "*" || token == "x" || token == "X" { return op.hasPrefix("<") && op != "<=" ? [{ _ in false }] : [] }
        guard let b = bounds(token), let numbers = numbers(token) else { return nil }
        let exact = numbers.count == 3
        switch op {
        case "", "=":
            if exact { return [{ VersionOrder.compare($0, b.low) == .orderedSame }] }
            return [atLeast(b.low), b.high.map(below) ?? { _ in true }]
        case ">=":
            return [atLeast(b.low)]
        case ">":
            // « >1.2 » : au-delà de toute la série 1.2.x.
            guard let high = b.high else { return [{ _ in false }] }
            return exact ? [{ VersionOrder.compare($0, b.low) == .orderedDescending }] : [atLeast(high)]
        case "<":
            return [below(b.low)]
        case "<=":
            guard let high = b.high else { return [{ _ in true }] }
            return exact ? [{ VersionOrder.compare($0, b.low) != .orderedDescending }] : [below(high)]
        case "~", "~>":
            // ~1.2.3 → <1.3.0 ; ~1.2 → <1.3.0 ; ~1 → <2.0.0
            let high = numbers.count >= 2 ? "\(numbers[0]).\(numbers[1] + 1).0" : "\(numbers[0] + 1).0.0"
            return [atLeast(b.low), below(high)]
        case "^":
            // ^1.2.3 → <2.0.0 ; ^0.2.3 → <0.3.0 ; ^0.0.3 → <0.0.4 ; ^0.x → <1.0.0
            let high: String
            if numbers[0] > 0 || numbers.count == 1 {
                high = "\(numbers[0] + 1).0.0"
            } else if numbers[1] > 0 || numbers.count == 2 {
                high = "0.\(numbers[1] + 1).0"
            } else {
                high = "0.0.\(numbers[2] + 1)"
            }
            return [atLeast(b.low), below(high)]
        default:
            return nil
        }
    }

    /// « 1.2 » → [1.2.0, 1.3.0) ; « 1.2.3 » → [1.2.3, 1.2.3] (borne haute `nil` : version exacte comparée à part).
    private static func bounds(_ token: String) -> (low: String, high: String?)? {
        guard let numbers = numbers(token) else { return nil }
        switch numbers.count {
        case 1: return ("\(numbers[0]).0.0", "\(numbers[0] + 1).0.0")
        case 2: return ("\(numbers[0]).\(numbers[1]).0", "\(numbers[0]).\(numbers[1] + 1).0")
        default:
            // Version complète : borne haute juste au-dessus d'elle.
            let low = token.hasPrefix("v") ? String(token.dropFirst()) : token
            return (low, nil)
        }
    }

    /// Parties numériques avant le premier joker ; préversion conservée à part dans `bounds`.
    private static func numbers(_ token: String) -> [Int]? {
        var core = token.hasPrefix("v") ? String(token.dropFirst()) : token
        if let cut = core.firstIndex(where: { $0 == "-" || $0 == "+" }) { core = String(core[..<cut]) }
        var result: [Int] = []
        for piece in core.split(separator: ".", omittingEmptySubsequences: false) {
            if ["x", "X", "*"].contains(piece) { break }
            guard let value = Int(piece) else { return nil }
            result.append(value)
        }
        guard (1...3).contains(result.count) else { return nil }
        return result
    }

    private static func parts(_ version: String) -> [Int]? {
        let numbers = UpdateGap.numericParts(version)
        return numbers.isEmpty ? nil : numbers
    }

    private static func atLeast(_ low: String) -> Check {
        { VersionOrder.compare($0, low) != .orderedAscending }
    }

    private static func below(_ high: String) -> Check {
        { version in
            let order = VersionOrder.compare(version, high)
            if order == .orderedAscending {
                // « <2.0.0 » exclut « 2.0.0-rc.1 » (node-semver).
                return !(VersionOrder.isPrerelease(version) && UpdateGap.numericParts(version).prefix(3) == UpdateGap.numericParts(high).prefix(3))
            }
            return false
        }
    }
}

// MARK: - Qui demande quoi, d'après les lockfiles

extension YarnLock {
    /// Pour chaque paquet, les paquets qui le demandent et avec quel intervalle (Yarn 1 et Berry).
    public static func requirements(_ text: String) -> [String: [DependencyRequirement]] {
        var result: [String: [DependencyRequirement]] = [:]
        var parent: String?
        var version: String?
        var pending: [(String, String)] = []
        var inDependencies = false

        func flush() {
            if let parent, let version {
                for (name, range) in pending {
                    result[name, default: []].append(DependencyRequirement(parent: parent, parentVersion: version, range: range))
                }
            }
            pending = []
            inDependencies = false
        }

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 {
                flush()
                parent = nil
                version = nil
                guard !line.hasPrefix("#"), line.hasSuffix(":") else { continue }
                let first = line.dropLast().split(separator: ",").first.map {
                    $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                } ?? ""
                parent = name(fromSpec: first)
                continue
            }
            guard parent != nil else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if indent == 2 {
                inDependencies = trimmed == "dependencies:" || trimmed == "optionalDependencies:"
                if trimmed.hasPrefix("version ") || trimmed.hasPrefix("version:") {
                    version = trimmed.dropFirst("version".count).trimmingCharacters(in: CharacterSet(charactersIn: ": \""))
                }
                continue
            }
            guard inDependencies, indent >= 4, let entry = dependencyLine(trimmed) else { continue }
            pending.append(entry)
        }
        flush()
        return result
    }

    /// `proxy-addr "~2.0.7"` (Yarn 1) ; `proxy-addr: "npm:~2.0.7"` ou `"@a/b": ^1` (Berry).
    static func dependencyLine(_ line: String) -> (String, String)? {
        var rest = Substring(line)
        let name: String
        if rest.hasPrefix("\"") {
            rest = rest.dropFirst()
            guard let close = rest.firstIndex(of: "\"") else { return nil }
            name = String(rest[..<close])
            rest = rest[rest.index(after: close)...]
        } else {
            guard let end = rest.firstIndex(where: { $0 == " " || $0 == ":" }) else { return nil }
            name = String(rest[..<end])
            rest = rest[end...]
        }
        let range = rest.trimmingCharacters(in: CharacterSet(charactersIn: ": \""))
        guard !name.isEmpty, !range.isEmpty else { return nil }
        return (name, range)
    }
}

extension NpmLock {
    /// lockfileVersion 2 et 3 : champ `dependencies` de chaque entrée de `packages`.
    public static func requirements(_ data: Data) -> [String: [DependencyRequirement]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let packages = object["packages"] as? [String: [String: Any]] else { return [:] }
        var result: [String: [DependencyRequirement]] = [:]
        for (key, entry) in packages {
            guard let range = key.range(of: "node_modules/", options: .backwards),
                  let version = entry["version"] as? String else { continue }
            let parent = String(key[range.upperBound...])
            for field in ["dependencies", "optionalDependencies"] {
                for (name, wanted) in (entry[field] as? [String: String]) ?? [:] {
                    result[name, default: []].append(DependencyRequirement(parent: parent, parentVersion: version, range: wanted))
                }
            }
        }
        return result
    }
}

// MARK: - Forcer une version (overrides / resolutions)

public enum DependencyOverride {
    /// Champ de `package.json` qui force une version, selon le gestionnaire.
    public static func field(for manager: PackageManager) -> String? {
        switch manager {
        case .npm: "overrides"
        case .yarn, .yarnBerry: "resolutions"
        default: nil
        }
    }

    /// Commande qui réinstalle en tenant compte du champ ajouté.
    public static func install(for manager: PackageManager, in project: URL) -> CommandSpec? {
        switch manager {
        case .npm: CommandSpec("npm", ["install"], in: project)
        case .yarn, .yarnBerry: CommandSpec("yarn", ["install"], in: project)
        default: nil
        }
    }

    /// Ajoute (ou remplace) `"name": "value"` dans le bloc `field` de premier niveau, en gardant le reste du fichier intact.
    /// `nil` si le JSON est illisible ou si le bloc existant n'est pas un simple objet de chaînes.
    public static func set(_ name: String, to value: String, field: String, in json: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        let quotedName = quote(name), quotedValue = quote(value)
        if let existing = object[field] {
            guard let entries = existing as? [String: Any] else { return nil }
            // npm : `"qs": { ".": … }` imbriqué ; on ne touche pas.
            if let current = entries[name], !(current is String) { return nil }
            guard let block = blockRange(field, in: json) else { return nil }
            let inner = String(json[block])
            let indent = innerIndent(inner) ?? childIndent(of: json, block: block)
            let rebuilt: String
            if entries[name] != nil, let line = inner.range(
                of: NSRegularExpression.escapedPattern(for: quotedName) + #"\s*:\s*"(?:[^"\\]|\\.)*""#, options: .regularExpression
            ) {
                rebuilt = inner.replacingCharacters(in: line, with: "\(quotedName): \(quotedValue)")
            } else {
                let trimmed = inner.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
                let closing = String(inner.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
                let newLine = "\(indent)\(quotedName): \(quotedValue)"
                rebuilt = trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "\n\(newLine)\n\(closing)"
                    : "\(trimmed),\n\(newLine)\n\(closing)"
            }
            return json.replacingCharacters(in: block, with: rebuilt)
        }
        // Pas de bloc : on l'ajoute à la fin de l'objet racine.
        guard let close = json.lastIndex(of: "}") else { return nil }
        let body = json[..<close]
        let unit = topIndent(json) ?? "  "
        let trimmed = body.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        let block = "\(unit)\(quote(field)): {\n\(unit)\(unit)\(quotedName): \(quotedValue)\n\(unit)}"
        let separator = trimmed.hasSuffix("{") ? "\n" : ",\n"
        return trimmed + separator + block + "\n" + String(json[close...])
    }

    private static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Contenu entre les accolades du bloc `"field": { … }` de premier niveau.
    private static func blockRange(_ field: String, in json: String) -> Range<String.Index>? {
        var depth = 0
        var index = json.startIndex
        var inString = false
        var escaped = false
        var stringStart = json.startIndex
        var lastKey: String?
        while index < json.endIndex {
            let c = json[index]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" {
                    inString = false
                    if depth == 1 { lastKey = String(json[json.index(after: stringStart)..<index]) }
                }
            } else if c == "\"" {
                inString = true
                stringStart = index
            } else if c == "{" {
                depth += 1
                if depth == 2, lastKey == field {
                    let start = json.index(after: index)
                    guard let end = matchingBrace(json, from: start) else { return nil }
                    return start..<end
                }
            } else if c == "}" {
                depth -= 1
            } else if c == ",", depth == 1 {
                lastKey = nil
            }
            index = json.index(after: index)
        }
        return nil
    }

    private static func matchingBrace(_ json: String, from start: String.Index) -> String.Index? {
        var depth = 1
        var index = start
        var inString = false
        var escaped = false
        while index < json.endIndex {
            let c = json[index]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { return index } }
            index = json.index(after: index)
        }
        return nil
    }

    private static func innerIndent(_ inner: String) -> String? {
        inner.split(separator: "\n").first { $0.contains("\"") }.map { String($0.prefix { $0 == " " || $0 == "\t" }) }
    }

    private static func childIndent(of json: String, block: Range<String.Index>) -> String {
        let unit = topIndent(json) ?? "  "
        return unit + unit
    }

    /// Indentation des clés de premier niveau.
    private static func topIndent(_ json: String) -> String? {
        json.split(separator: "\n").dropFirst().first { $0.contains("\"") }.map { String($0.prefix { $0 == " " || $0 == "\t" }) }
    }
}

// MARK: - Vérification après correction

/// Ce qu'une correction doit avoir changé : `name` n'est plus en `vulnerableVersion` dans le projet.
public struct DependencyExpectation: Sendable, Hashable {
    public var project: URL
    /// Lockfile (ou manifeste) où la version vulnérable a été lue.
    public var file: String
    public var name: String
    public var vulnerableVersion: String

    public init(project: URL, file: String, name: String, vulnerableVersion: String) {
        self.project = project
        self.file = file
        self.name = name
        self.vulnerableVersion = vulnerableVersion
    }

    /// Celles dont la version vulnérable est toujours dans le lockfile.
    public static func unchanged(_ expected: [DependencyExpectation]) -> [DependencyExpectation] {
        var manifests: [URL: [ProjectManifest]] = [:]
        return expected.filter { item in
            let read = manifests[item.project] ?? DependencyReader.read(project: item.project)
            manifests[item.project] = read
            let same = read.filter { ($0.lockfile ?? $0.manifest) == item.file }
            return (same.isEmpty ? read : same).contains { manifest in
                manifest.dependencies.contains { $0.name == item.name && $0.version == item.vulnerableVersion }
            }
        }
    }
}

// MARK: - Yarn 1 : sous-paquet à re-résoudre

extension YarnLock {
    /// Retire du lockfile les entrées de `name` en `version` : `yarn install` les re-résout alors
    /// à la dernière version permise par les parents (`yarn upgrade` ne le fait pas pour un sous-paquet).
    public static func removing(_ name: String, version: String, from text: String) -> (text: String, removed: [String])? {
        var lines = text.components(separatedBy: "\n")
        var removed: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard let first = line.first, !first.isWhitespace, first != "#", line.hasSuffix(":"),
                  line.dropLast().split(separator: ",").contains(where: {
                      self.name(fromSpec: $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))) == name
                  }) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < lines.count, lines[end].first.map({ $0.isWhitespace }) ?? false { end += 1 }
            let block = lines[index..<end]
            let entryVersion = block.lazy.map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("version ") || $0.hasPrefix("version:") }
                .map { $0.dropFirst("version".count).trimmingCharacters(in: CharacterSet(charactersIn: ": \"")) }
            guard entryVersion == version else {
                index = end
                continue
            }
            removed.append(String(line.dropLast()))
            // La ligne vide qui suit le bloc part avec lui.
            if end < lines.count, lines[end].isEmpty { end += 1 }
            lines.removeSubrange(index..<end)
        }
        return removed.isEmpty ? nil : (lines.joined(separator: "\n"), removed)
    }
}
