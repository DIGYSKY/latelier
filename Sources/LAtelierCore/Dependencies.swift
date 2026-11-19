import Foundation

// MARK: - Modèle

/// Écosystème d'une dépendance, avec son nom chez OSV.dev.
public enum Ecosystem: String, Sendable, Codable, CaseIterable, Hashable {
    case npm, cargo, pypi, go, maven, swift, packagist, rubygems

    public var label: String {
        switch self {
        case .npm: "npm"
        case .cargo: "Rust"
        case .pypi: "Python"
        case .go: "Go"
        case .maven: "Maven"
        case .swift: "Swift"
        case .packagist: "PHP"
        case .rubygems: "Ruby"
        }
    }

    /// Nom de l'écosystème dans l'API OSV.
    public var osvName: String {
        switch self {
        case .npm: "npm"
        case .cargo: "crates.io"
        case .pypi: "PyPI"
        case .go: "Go"
        case .maven: "Maven"
        case .swift: "SwiftURL"
        case .packagist: "Packagist"
        case .rubygems: "RubyGems"
        }
    }
}

/// Outil qui gère les dépendances d'un projet : il donne la commande de mise à jour.
public enum PackageManager: String, Sendable, Codable, Hashable {
    case npm, yarn, yarnBerry, pnpm, bun, cargo, uv, poetry, pip, go, composer, swiftpm, maven, gradle, bundler

    public var label: String {
        switch self {
        case .npm: "npm"
        case .yarn, .yarnBerry: "Yarn"
        case .pnpm: "pnpm"
        case .bun: "Bun"
        case .cargo: "Cargo"
        case .uv: "uv"
        case .poetry: "Poetry"
        case .pip: "pip"
        case .go: "Go"
        case .composer: "Composer"
        case .swiftpm: "SwiftPM"
        case .maven: "Maven"
        case .gradle: "Gradle"
        case .bundler: "Bundler"
        }
    }
}

/// Une dépendance d'un projet, telle que lue dans son lockfile (ou son manifeste à défaut).
public struct Dependency: Sendable, Hashable, Codable {
    public var ecosystem: Ecosystem
    public var name: String
    /// Version résolue ; vide si seul un intervalle est connu (pas de lockfile).
    public var version: String
    /// Ce que demande le manifeste (« ^18.2.0 »), pour les dépendances directes.
    public var requirement: String?
    public var direct: Bool
    public var dev: Bool
    public var license: String?

    public init(
        ecosystem: Ecosystem, name: String, version: String, requirement: String? = nil,
        direct: Bool = false, dev: Bool = false, license: String? = nil
    ) {
        self.ecosystem = ecosystem
        self.name = name
        self.version = version
        self.requirement = requirement
        self.direct = direct
        self.dev = dev
        self.license = license
    }

    /// Identifie une bibliothèque, toutes versions confondues.
    public var libraryKey: String { "\(ecosystem.rawValue):\(name)" }
    /// Identifie une bibliothèque dans une version précise.
    public var versionKey: String { "\(libraryKey)@\(version)" }
}

/// Un manifeste lu dans un projet (un projet PHP + JS en a deux).
public struct ProjectManifest: Sendable, Identifiable {
    public var project: URL
    public var ecosystem: Ecosystem
    public var manager: PackageManager
    /// Fichier lu pour les dépendances directes (`package.json`).
    public var manifest: String
    /// Lockfile utilisé ; `nil` : versions déduites du manifeste.
    public var lockfile: String?
    /// Autres lockfiles trouvés pour le même écosystème (npm + yarn…).
    public var extraLockfiles: [String] = []
    public var dependencies: [Dependency]

    public var id: String { "\(project.path)#\(manifest)" }
    public var projectName: String { project.lastPathComponent }
    public var direct: [Dependency] { dependencies.filter(\.direct) }
}

// MARK: - Ordre des versions

public enum VersionOrder {
    /// Compare deux versions sur leurs parties numériques (« 1.10.0 » > « 1.9.3 »).
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = UpdateGap.numericParts(a), y = UpdateGap.numericParts(b)
        for index in 0..<max(x.count, y.count) {
            let l = index < x.count ? x[index] : 0
            let r = index < y.count ? y[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        // À parties égales, une préversion (« 2.0.0-rc.1 ») vient avant la version finale.
        let preA = isPrerelease(a), preB = isPrerelease(b)
        if preA != preB { return preA ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }

    public static func isPrerelease(_ version: String) -> Bool {
        let lowered = version.lowercased()
        return ["-alpha", "-beta", "-rc", "-pre", "-dev", "-canary", "-next", "a", "b", "rc", ".dev"].contains { marker in
            if marker.count <= 2 {
                // « 2.0b1 », « 3.0rc2 » (PyPI) : marqueur collé à un chiffre
                return lowered.range(of: "\\d\(marker)\\d", options: .regularExpression) != nil
            }
            return lowered.contains(marker)
        }
    }

    /// Plus petite version minimale d'un intervalle simple : « ^18.2.0 » → 18.2.0, « >=2.31,<3 » → 2.31.
    public static func floor(of requirement: String) -> String? {
        let first = requirement.split(whereSeparator: { $0 == "," || $0 == "|" || $0 == " " }).first.map(String.init) ?? requirement
        let trimmed = first.drop { "^~>=<!v ".contains($0) }
        guard let head = trimmed.first, head.isNumber else { return nil }
        let version = trimmed.prefix { $0.isNumber || $0 == "." }
        let cleaned = version.hasSuffix(".") ? String(version.dropLast()) : String(version)
        return cleaned.isEmpty ? nil : cleaned
    }
}

// MARK: - Lecture d'un projet

public enum DependencyReader {
    /// Manifestes trouvés à la racine du projet (et dans les membres d'un workspace Cargo).
    public static func read(project: URL) -> [ProjectManifest] {
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: project.path)) ?? [])
        func data(_ name: String) -> Data? { try? Data(contentsOf: project.appending(path: name)) }
        func text(_ name: String) -> String? { data(name).flatMap { String(data: $0, encoding: .utf8) } }
        var result: [ProjectManifest] = []

        if files.contains("package.json"), let manifest = data("package.json") {
            result.append(javascript(project: project, files: files, manifest: manifest, text: text))
        }
        if files.contains("Cargo.toml"), let toml = text("Cargo.toml") {
            var direct = CargoToml.parse(toml)
            if toml.contains("[workspace]") {
                for member in CargoToml.members(toml) {
                    if let sub = try? String(contentsOf: project.appending(path: "\(member)/Cargo.toml"), encoding: .utf8) {
                        direct.merge(CargoToml.parse(sub)) { a, _ in a }
                    }
                }
            }
            let locked = text("Cargo.lock").map(CargoLock.parse)
            result.append(ProjectManifest(
                project: project, ecosystem: .cargo, manager: .cargo, manifest: "Cargo.toml",
                lockfile: locked == nil ? nil : "Cargo.lock",
                dependencies: merge(locked: locked, direct: direct, ecosystem: .cargo)
            ))
        }
        if let python = python(project: project, files: files, text: text) { result.append(python) }
        if files.contains("go.mod"), let mod = text("go.mod") {
            result.append(ProjectManifest(
                project: project, ecosystem: .go, manager: .go, manifest: "go.mod", lockfile: "go.mod",
                dependencies: GoMod.parse(mod)
            ))
        }
        if files.contains("composer.json"), let manifest = data("composer.json") {
            let direct = Composer.parseManifest(manifest)
            let locked = data("composer.lock").map(Composer.parseLock)
            result.append(ProjectManifest(
                project: project, ecosystem: .packagist, manager: .composer, manifest: "composer.json",
                lockfile: locked == nil ? nil : "composer.lock",
                dependencies: merge(locked: locked, direct: direct, ecosystem: .packagist)
            ))
        }
        if files.contains("Package.swift") {
            let direct = text("Package.swift").map(SwiftPackage.parseManifest) ?? [:]
            let locked = data("Package.resolved").map(SwiftPackage.parseResolved)
            if !direct.isEmpty || !(locked ?? []).isEmpty {
                result.append(ProjectManifest(
                    project: project, ecosystem: .swift, manager: .swiftpm, manifest: "Package.swift",
                    lockfile: locked == nil ? nil : "Package.resolved",
                    dependencies: merge(locked: locked, direct: direct, ecosystem: .swift)
                ))
            }
        }
        if files.contains("pom.xml"), let pom = text("pom.xml") {
            result.append(ProjectManifest(
                project: project, ecosystem: .maven, manager: .maven, manifest: "pom.xml", lockfile: nil,
                dependencies: Maven.parsePom(pom)
            ))
        } else if let gradle = ["build.gradle.kts", "build.gradle"].first(where: files.contains), let script = text(gradle) {
            result.append(ProjectManifest(
                project: project, ecosystem: .maven, manager: .gradle, manifest: gradle, lockfile: nil,
                dependencies: Maven.parseGradle(script)
            ))
        }
        if files.contains("Gemfile") {
            let locked = text("Gemfile.lock").map(GemfileLock.parse)
            result.append(ProjectManifest(
                project: project, ecosystem: .rubygems, manager: .bundler, manifest: "Gemfile",
                lockfile: locked == nil ? nil : "Gemfile.lock", dependencies: locked ?? []
            ))
        }
        return result
    }

    private static func javascript(project: URL, files: Set<String>, manifest: Data, text: (String) -> String?) -> ProjectManifest {
        let info = PackageJSON.parse(manifest)
        let candidates = ["pnpm-lock.yaml", "yarn.lock", "package-lock.json", "bun.lock", "npm-shrinkwrap.json"].filter(files.contains)
        // Plusieurs lockfiles : le gestionnaire déclaré l'emporte, sinon le plus récent.
        let declared = info.packageManager.flatMap { pm in
            candidates.first { lock in
                (pm == "pnpm" && lock == "pnpm-lock.yaml") || (pm == "yarn" && lock == "yarn.lock")
                    || (pm == "npm" && lock == "package-lock.json") || (pm == "bun" && lock == "bun.lock")
            }
        }
        let newest = candidates.max { a, b in modified(project.appending(path: a)) < modified(project.appending(path: b)) }
        let chosen = declared ?? newest
        var manager = PackageManager.npm
        var locked: [Dependency]?
        switch chosen {
        case "pnpm-lock.yaml":
            manager = .pnpm
            locked = text("pnpm-lock.yaml").map(PnpmLock.parse)
        case "yarn.lock":
            let lock = text("yarn.lock") ?? ""
            manager = lock.contains("__metadata:") ? .yarnBerry : .yarn
            locked = YarnLock.parse(lock)
        case "package-lock.json", "npm-shrinkwrap.json":
            locked = (try? Data(contentsOf: project.appending(path: chosen!))).map(NpmLock.parse)
        case "bun.lock":
            manager = .bun
        default:
            if info.packageManager == "pnpm" { manager = .pnpm } else if info.packageManager == "yarn" { manager = .yarn }
        }
        var direct = info.dependencies
        for (name, range) in info.devDependencies where direct[name] == nil { direct[name] = (range, true) }
        let readable = chosen == "bun.lock" ? nil : chosen
        return ProjectManifest(
            project: project, ecosystem: .npm, manager: manager, manifest: "package.json",
            lockfile: locked == nil ? nil : readable,
            extraLockfiles: candidates.filter { $0 != chosen },
            dependencies: merge(locked: locked, direct: direct.mapValues { ($0.range, $0.dev) }, ecosystem: .npm)
        )
    }

    private static func python(project: URL, files: Set<String>, text: (String) -> String?) -> ProjectManifest? {
        let pyproject = text("pyproject.toml")
        let direct = pyproject.map(PyProject.parse) ?? [:]
        if files.contains("uv.lock"), let lock = text("uv.lock") {
            return ProjectManifest(project: project, ecosystem: .pypi, manager: .uv, manifest: "pyproject.toml", lockfile: "uv.lock",
                                   dependencies: merge(locked: TomlLock.parse(lock), direct: direct, ecosystem: .pypi))
        }
        if files.contains("poetry.lock"), let lock = text("poetry.lock") {
            return ProjectManifest(project: project, ecosystem: .pypi, manager: .poetry, manifest: "pyproject.toml", lockfile: "poetry.lock",
                                   dependencies: merge(locked: TomlLock.parse(lock), direct: direct, ecosystem: .pypi))
        }
        let requirements = files.filter { $0.hasPrefix("requirements") && $0.hasSuffix(".txt") && !$0.contains("old") }.sorted()
        if let main = requirements.first(where: { $0 == "requirements.txt" }) ?? requirements.first {
            var deps: [Dependency] = []
            for file in requirements {
                let dev = file != main && (file.contains("dev") || file.contains("test"))
                deps += Requirements.parse(text(file) ?? "", dev: dev)
            }
            var seen = Set<String>()
            deps = deps.filter { seen.insert($0.name).inserted }
            return ProjectManifest(project: project, ecosystem: .pypi, manager: .pip, manifest: main,
                                   lockfile: deps.allSatisfy { !$0.version.isEmpty } ? main : nil, dependencies: deps)
        }
        guard pyproject != nil, !direct.isEmpty else { return nil }
        let manager: PackageManager = pyproject!.contains("[tool.poetry") ? .poetry : .uv
        return ProjectManifest(project: project, ecosystem: .pypi, manager: manager, manifest: "pyproject.toml", lockfile: nil,
                               dependencies: merge(locked: nil, direct: direct, ecosystem: .pypi))
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Croise le lockfile (versions exactes) et le manifeste (ce qui est direct, et en dev).
    static func merge(locked: [Dependency]?, direct: [String: (range: String, dev: Bool)], ecosystem: Ecosystem) -> [Dependency] {
        func normalize(_ name: String) -> String { ecosystem == .pypi ? PyProject.normalize(name) : name }
        let wanted = Dictionary(direct.map { (normalize($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        guard let locked else {
            return wanted.map { name, value in
                Dependency(ecosystem: ecosystem, name: name, version: VersionOrder.floor(of: value.range) ?? "",
                           requirement: value.range, direct: true, dev: value.dev)
            }
            .sorted { $0.name < $1.name }
        }
        var result: [Dependency] = []
        var seenDirect = Set<String>()
        // Plusieurs versions d'un même paquet : la directe est celle qui satisfait le plancher demandé.
        let grouped = Dictionary(grouping: locked) { normalize($0.name) }
        for (name, versions) in grouped {
            guard let want = wanted[name] else {
                result += versions.map { var d = $0; d.direct = false; return d }
                continue
            }
            let floor = VersionOrder.floor(of: want.range)
            let best = versions.first { $0.direct } ?? versions.first { dep in
                guard let floor else { return true }
                return UpdateGap.numericParts(dep.version).first == UpdateGap.numericParts(floor).first
            } ?? versions.max { VersionOrder.compare($0.version, $1.version) == .orderedAscending }
            for dep in versions {
                var dep = dep
                dep.name = name
                if dep.version == best?.version, seenDirect.insert(name).inserted {
                    dep.direct = true
                    dep.dev = want.dev
                    dep.requirement = want.range
                } else {
                    dep.direct = false
                }
                result.append(dep)
            }
        }
        // Déclarées mais absentes du lockfile (lockfile pas à jour) : on garde l'intervalle.
        for (name, value) in wanted where grouped[name] == nil {
            result.append(Dependency(ecosystem: ecosystem, name: name, version: VersionOrder.floor(of: value.range) ?? "",
                                     requirement: value.range, direct: true, dev: value.dev))
        }
        return result.sorted { ($0.name, $0.version) < ($1.name, $1.version) }
    }
}

// MARK: - JavaScript

public enum PackageJSON {
    public struct Info: Sendable {
        public var dependencies: [String: (range: String, dev: Bool)] = [:]
        public var devDependencies: [String: String] = [:]
        public var packageManager: String?
    }

    public static func parse(_ data: Data) -> Info {
        var info = Info()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return info }
        for key in ["dependencies", "optionalDependencies", "peerDependencies"] {
            for (name, range) in (object[key] as? [String: String]) ?? [:] where isRegistry(range) && info.dependencies[name] == nil {
                info.dependencies[name] = (range, false)
            }
        }
        for (name, range) in (object["devDependencies"] as? [String: String]) ?? [:] where isRegistry(range) {
            info.devDependencies[name] = range
        }
        if let pm = object["packageManager"] as? String {
            info.packageManager = pm.split(separator: "@").first.map(String.init)
        }
        return info
    }

    /// Exclut `file:`, `link:`, `workspace:`, `git+…`, URL et alias : rien de fiable à demander au registre.
    static func isRegistry(_ range: String) -> Bool {
        // « npm:autre-paquet@x » : alias, la version est celle d'un autre paquet.
        !["file:", "link:", "workspace:", "git", "http:", "https:", "github:", "portal:", "patch:", "npm:"].contains { range.hasPrefix($0) }
            && !range.contains("/")
    }
}

public enum NpmLock {
    public static func parse(_ data: Data) -> [Dependency] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let packages = object["packages"] as? [String: [String: Any]] {
            return packages.compactMap { key, entry in
                guard let range = key.range(of: "node_modules/", options: .backwards),
                      entry["link"] as? Bool != true,
                      let version = entry["version"] as? String else { return nil }
                let name = String(key[range.upperBound...])
                // Paquet installé directement à la racine : candidat « direct », le manifeste tranche.
                let topLevel = key == "node_modules/\(name)"
                return Dependency(ecosystem: .npm, name: name, version: version, direct: topLevel,
                                  dev: entry["dev"] as? Bool ?? false, license: entry["license"] as? String)
            }
        }
        // lockfileVersion 1 : arbre « dependencies » imbriqué
        var result: [Dependency] = []
        func walk(_ tree: [String: Any], depth: Int) {
            for (name, value) in tree {
                guard let entry = value as? [String: Any], let version = entry["version"] as? String else { continue }
                if !version.contains(":") {
                    result.append(Dependency(ecosystem: .npm, name: name, version: version, direct: depth == 0,
                                             dev: entry["dev"] as? Bool ?? false))
                }
                if let nested = entry["dependencies"] as? [String: Any] { walk(nested, depth: depth + 1) }
            }
        }
        walk(object["dependencies"] as? [String: Any] ?? [:], depth: 0)
        return result
    }
}

public enum YarnLock {
    /// Yarn 1 (`version "1.2.3"`) et Yarn Berry (`version: 1.2.3`).
    public static func parse(_ text: String) -> [Dependency] {
        var result: [Dependency] = []
        var currentName: String?
        var seen = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            if line.first.map({ !$0.isWhitespace }) == true {
                currentName = nil
                guard !line.hasPrefix("#"), line.hasSuffix(":") else { continue }
                let first = line.dropLast().split(separator: ",").first.map {
                    $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                } ?? ""
                if ["@workspace:", "@patch:", "@link:", "@file:", "@portal:", "@exec:", "@git", "@https:"].contains(where: first.contains) { continue }
                currentName = name(fromSpec: first)
            } else if let name = currentName {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("version ") || trimmed.hasPrefix("version:") else { continue }
                let version = trimmed.dropFirst("version".count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ": \""))
                if seen.insert("\(name)@\(version)").inserted {
                    result.append(Dependency(ecosystem: .npm, name: name, version: version))
                }
                currentName = nil
            }
        }
        return result
    }

    /// « @babel/core@^7.0.0 » → « @babel/core » ; « lodash@npm:^4 » → « lodash ».
    static func name(fromSpec spec: String) -> String? {
        let body = spec.hasPrefix("@") ? spec.dropFirst() : Substring(spec)
        guard let at = body.firstIndex(of: "@") else { return nil }
        let name = (spec.hasPrefix("@") ? "@" : "") + body[..<at]
        return name.isEmpty || name == "__metadata" ? nil : name
    }
}

public enum PnpmLock {
    /// Section `packages:` : « /name@1.2.3: » (v6), « /name/1.2.3: » (v5), « name@1.2.3: » (v9).
    public static func parse(_ text: String) -> [Dependency] {
        var result: [Dependency] = []
        var inPackages = false
        var last: Int?
        var seen = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if !line.hasPrefix(" ") {
                inPackages = line.hasPrefix("packages:")
                continue
            }
            guard inPackages else { continue }
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if indent == 2, trimmed.hasSuffix(":") {
                last = nil
                var key = String(trimmed.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                if let paren = key.firstIndex(of: "(") { key = String(key[..<paren]) }
                if key.hasPrefix("/") { key.removeFirst() }
                guard let (name, version) = split(key), seen.insert("\(name)@\(version)").inserted else { continue }
                result.append(Dependency(ecosystem: .npm, name: name, version: version))
                last = result.count - 1
            } else if indent == 4, trimmed == "dev: true", let index = last {
                result[index].dev = true
            }
        }
        return result
    }

    private static func split(_ key: String) -> (String, String)? {
        let body = key.hasPrefix("@") ? key.dropFirst() : Substring(key)
        if let at = body.lastIndex(of: "@") {
            let name = (key.hasPrefix("@") ? "@" : "") + body[..<at]
            let version = String(body[body.index(after: at)...])
            guard version.first?.isNumber == true else { return nil }
            return (name, version.split(separator: "_").first.map(String.init) ?? version)
        }
        // v5 : « @scope/name/1.2.3 »
        guard let slash = key.lastIndex(of: "/") else { return nil }
        let version = String(key[key.index(after: slash)...])
        guard version.first?.isNumber == true else { return nil }
        return (String(key[..<slash]), version.split(separator: "_").first.map(String.init) ?? version)
    }
}

// MARK: - Rust

public enum CargoLock {
    public static func parse(_ text: String) -> [Dependency] {
        TomlLock.blocks(text).compactMap { block in
            guard let name = block["name"], let version = block["version"],
                  block["source"]?.hasPrefix("registry+") == true || block["source"]?.hasPrefix("sparse+") == true
            else { return nil }
            return Dependency(ecosystem: .cargo, name: name, version: version)
        }
    }
}

public enum CargoToml {
    /// Dépendances déclarées : nom → (exigence, dev).
    public static func parse(_ text: String) -> [String: (range: String, dev: Bool)] {
        var result: [String: (range: String, dev: Bool)] = [:]
        var section = ""
        var tableDependency: (name: String, dev: Bool)?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? ""
            if line.hasPrefix("[") {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                tableDependency = nil
                // [dependencies.serde] : table dédiée
                for kind in ["dependencies", "dev-dependencies", "build-dependencies"] where section.contains("\(kind).") {
                    if let name = section.components(separatedBy: "\(kind).").last, !name.isEmpty {
                        tableDependency = (name, kind == "dev-dependencies")
                        result[name] = ("*", kind == "dev-dependencies")
                    }
                }
                continue
            }
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = line[..<equal].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            if let table = tableDependency {
                if key == "version" { result[table.name] = (value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")), table.dev) }
                continue
            }
            let isDeps = section.hasSuffix("dependencies")
            guard isDeps, !value.contains("path =") || value.contains("version") else { continue }
            if value.contains("workspace = true") || value.contains("workspace=true") {
                if result[key] == nil { result[key] = ("*", section.contains("dev-")) }
                continue
            }
            var range = "*"
            if value.hasPrefix("\"") {
                range = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if let match = value.range(of: #"version\s*=\s*"([^"]+)""#, options: .regularExpression) {
                range = String(value[match]).components(separatedBy: "\"").dropFirst().first ?? "*"
            }
            let realName = value.range(of: #"package\s*=\s*"([^"]+)""#, options: .regularExpression)
                .flatMap { String(value[$0]).components(separatedBy: "\"").dropFirst().first } ?? key
            let existing = result[realName]
            if existing == nil || existing?.range == "*" { result[realName] = (range, section.contains("dev-")) }
        }
        return result
    }

    /// Membres d'un workspace : `members = ["a", "crates/b"]` (sans les motifs `*`).
    public static func members(_ text: String) -> [String] {
        guard let start = text.range(of: "members") else { return [] }
        let rest = text[start.upperBound...]
        guard let open = rest.firstIndex(of: "["), let close = rest.firstIndex(of: "]") , open < close else { return [] }
        return rest[rest.index(after: open)..<close].split(separator: ",").compactMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return value.isEmpty || value.contains("*") ? nil : value
        }
    }
}

/// Lockfiles TOML à blocs `[[package]]` : Cargo.lock, uv.lock, poetry.lock.
public enum TomlLock {
    static func blocks(_ text: String) -> [[String: String]] {
        var blocks: [[String: String]] = []
        var current: [String: String]?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "[[package]]" {
                if let current { blocks.append(current) }
                current = [:]
                continue
            }
            if line.hasPrefix("[") {
                if let block = current { blocks.append(block) }
                current = nil
                continue
            }
            guard current != nil, let equal = line.firstIndex(of: "=") else { continue }
            let key = line[..<equal].trimmingCharacters(in: .whitespaces)
            guard current?[key] == nil else { continue }
            current?[key] = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        if let current { blocks.append(current) }
        return blocks
    }

    /// uv.lock / poetry.lock : on ignore le projet lui-même (`editable`, `virtual`) et les sources locales.
    public static func parse(_ text: String) -> [Dependency] {
        blocks(text).compactMap { block in
            guard let name = block["name"], let version = block["version"] else { return nil }
            if let source = block["source"], ["editable", "virtual", "directory", "path", "git"].contains(where: source.contains) { return nil }
            return Dependency(ecosystem: .pypi, name: PyProject.normalize(name), version: version)
        }
    }
}

// MARK: - Python

public enum PyProject {
    /// PEP 503 : « Flask_Login » → « flask-login ».
    public static func normalize(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "[-_.]+", with: "-", options: .regularExpression)
    }

    /// `[project] dependencies`, groupes de dev, et `[tool.poetry.*dependencies]`.
    public static func parse(_ text: String) -> [String: (range: String, dev: Bool)] {
        var result: [String: (range: String, dev: Bool)] = [:]
        var section = ""
        var arrayDev: Bool?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && arrayDev == nil {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                continue
            }
            if let dev = arrayDev {
                // Élément d'un tableau multi-ligne : "requests>=2.31",
                for item in line.split(separator: ",") {
                    if let (name, range) = requirement(item.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))) {
                        result[name] = result[name] ?? (range, dev)
                    }
                }
                if line.contains("]") { arrayDev = nil }
                continue
            }
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = line[..<equal].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            let isArray = (section == "project" && key == "dependencies")
                || section == "dependency-groups" || section == "project.optional-dependencies"
                || (section == "tool.uv" && key == "dev-dependencies")
            if isArray, value.hasPrefix("[") {
                let dev = section != "project" && section != "project.optional-dependencies"
                let inner = value.dropFirst()
                for item in inner.split(separator: ",") {
                    if let (name, range) = requirement(item.trimmingCharacters(in: CharacterSet(charactersIn: " \"']"))) {
                        result[name] = result[name] ?? (range, dev)
                    }
                }
                if !value.contains("]") { arrayDev = dev }
                continue
            }
            if section.hasPrefix("tool.poetry") && section.hasSuffix("dependencies") {
                let name = key.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard name.lowercased() != "python" else { continue }
                var range = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if value.hasPrefix("{") {
                    range = value.range(of: #"version\s*=\s*"([^"]+)""#, options: .regularExpression)
                        .flatMap { String(value[$0]).components(separatedBy: "\"").dropFirst().first } ?? "*"
                }
                result[normalize(name)] = (range, section != "tool.poetry.dependencies")
            }
        }
        return result
    }

    /// « requests[socks]>=2.31; python_version>'3.8' » → (« requests », « >=2.31 »).
    static func requirement(_ text: String) -> (String, String)? {
        let spec = text.split(separator: ";").first.map(String.init) ?? text
        guard let first = spec.first, first.isLetter || first.isNumber else { return nil }
        let nameEnd = spec.firstIndex { !($0.isLetter || $0.isNumber || "-_.".contains($0)) } ?? spec.endIndex
        let name = normalize(String(spec[..<nameEnd]))
        var rest = spec[nameEnd...]
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") { rest = rest[rest.index(after: close)...] }
        let range = rest.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : (name, range.isEmpty ? "*" : range)
    }
}

public enum Requirements {
    /// `name==1.2.3` donne une version exacte ; `name>=1.2` seulement un plancher.
    public static func parse(_ text: String, dev: Bool = false) -> [Dependency] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !line.isEmpty, !line.hasPrefix("-"), !line.contains("://"),
                  let (name, range) = PyProject.requirement(line) else { return nil }
            let exact = range.hasPrefix("==") ? String(range.dropFirst(2)).trimmingCharacters(in: .whitespaces) : ""
            return Dependency(ecosystem: .pypi, name: name, version: exact.contains("*") ? "" : exact,
                              requirement: range, direct: true, dev: dev)
        }
    }
}

// MARK: - Go, PHP, Swift, Java, Ruby

public enum GoMod {
    public static func parse(_ text: String) -> [Dependency] {
        var result: [Dependency] = []
        var inRequire = false
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("require (") { inRequire = true; continue }
            if inRequire && line == ")" { inRequire = false; continue }
            if line.hasPrefix("require ") { line = String(line.dropFirst(8)) } else if !inRequire { continue }
            let indirect = line.contains("// indirect")
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { continue }
            let version = String(parts[1])
            result.append(Dependency(ecosystem: .go, name: String(parts[0]), version: version,
                                     requirement: indirect ? nil : version, direct: !indirect))
        }
        return result
    }
}

public enum Composer {
    static func isPlatform(_ name: String) -> Bool {
        name == "php" || name.hasPrefix("ext-") || name.hasPrefix("lib-") || name.hasPrefix("composer-") || !name.contains("/")
    }

    public static func parseManifest(_ data: Data) -> [String: (range: String, dev: Bool)] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: (range: String, dev: Bool)] = [:]
        for (name, range) in (object["require"] as? [String: String]) ?? [:] where !isPlatform(name) { result[name.lowercased()] = (range, false) }
        for (name, range) in (object["require-dev"] as? [String: String]) ?? [:] where !isPlatform(name) && result[name] == nil {
            result[name.lowercased()] = (range, true)
        }
        return result
    }

    public static func parseLock(_ data: Data) -> [Dependency] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return ["packages", "packages-dev"].flatMap { key in
            ((object[key] as? [[String: Any]]) ?? []).compactMap { entry -> Dependency? in
                guard let name = entry["name"] as? String, var version = entry["version"] as? String,
                      !version.hasPrefix("dev-") else { return nil }
                if version.hasPrefix("v") { version.removeFirst() }
                let license = (entry["license"] as? [String])?.joined(separator: " / ")
                return Dependency(ecosystem: .packagist, name: name.lowercased(), version: version, dev: key == "packages-dev", license: license)
            }
        }
    }
}

public enum SwiftPackage {
    /// « https://github.com/apple/swift-nio.git » → « github.com/apple/swift-nio » (nom OSV SwiftURL).
    public static func identity(_ url: String) -> String {
        var value = url.lowercased()
        for prefix in ["https://", "http://", "git@", "ssh://"] where value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        value = value.replacingOccurrences(of: ":", with: "/")
        if value.hasSuffix(".git") { value.removeLast(4) }
        if value.hasSuffix("/") { value.removeLast() }
        return value
    }

    public static func parseManifest(_ text: String) -> [String: (range: String, dev: Bool)] {
        var result: [String: (range: String, dev: Bool)] = [:]
        let pattern = #"\.package\(\s*(?:name:\s*"[^"]*",\s*)?url:\s*"([^"]+)"\s*,\s*(?:from:\s*"([^"]+)"|exact:\s*"([^"]+)"|\.upToNextMajor\(from:\s*"([^"]+)"\)|\.upToNextMinor\(from:\s*"([^"]+)"\)|"([^"]+)"\.\.\.?<?"[^"]+")?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let url = ns.substring(with: match.range(at: 1))
            let version = (2...6).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }.map(ns.substring(with:))
            result[identity(url)] = (version.map { "from: \($0)" } ?? "*", false)
        }
        return result
    }

    public static func parseResolved(_ data: Data) -> [Dependency] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let pins = (object["pins"] as? [[String: Any]]) ?? ((object["object"] as? [String: Any])?["pins"] as? [[String: Any]]) ?? []
        return pins.compactMap { pin in
            guard let location = (pin["location"] as? String) ?? (pin["repositoryURL"] as? String),
                  let state = pin["state"] as? [String: Any], let version = state["version"] as? String else { return nil }
            return Dependency(ecosystem: .swift, name: identity(location), version: version)
        }
    }
}

public enum Maven {
    public static func parsePom(_ text: String) -> [Dependency] {
        var properties: [String: String] = [:]
        if let block = between(text, "<properties>", "</properties>"),
           let regex = try? NSRegularExpression(pattern: #"<([A-Za-z0-9_.\-]+)>([^<]*)</\1>"#) {
            let ns = block as NSString
            for match in regex.matches(in: block, range: NSRange(location: 0, length: ns.length)) {
                properties[ns.substring(with: match.range(at: 1))] = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            }
        }
        if let version = between(text, "<version>", "</version>") { properties["project.version"] = version }
        var result: [Dependency] = []
        var rest = Substring(text)
        while let start = rest.range(of: "<dependency>"), let end = rest.range(of: "</dependency>", range: start.upperBound..<rest.endIndex) {
            let block = String(rest[start.upperBound..<end.lowerBound])
            rest = rest[end.upperBound...]
            guard let group = between(block, "<groupId>", "</groupId>"), let artifact = between(block, "<artifactId>", "</artifactId>") else { continue }
            var version = between(block, "<version>", "</version>") ?? ""
            if version.hasPrefix("${") { version = properties[String(version.dropFirst(2).dropLast())] ?? "" }
            if version.hasPrefix("[") || version.contains("$") { version = "" }
            let scope = between(block, "<scope>", "</scope>")
            let dep = Dependency(ecosystem: .maven, name: "\(group):\(artifact)", version: version, requirement: version.isEmpty ? nil : version,
                                 direct: true, dev: scope == "test")
            if !result.contains(where: { $0.name == dep.name }) { result.append(dep) }
        }
        return result
    }

    public static func parseGradle(_ text: String) -> [Dependency] {
        let pattern = #"(implementation|api|compileOnly|runtimeOnly|testImplementation|testRuntimeOnly|kapt|ksp|annotationProcessor)\s*\(?\s*["']([^:"'\s]+):([^:"'\s]+):([^"'$\s]+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            let conf = ns.substring(with: match.range(at: 1))
            let version = ns.substring(with: match.range(at: 4))
            return Dependency(ecosystem: .maven, name: "\(ns.substring(with: match.range(at: 2))):\(ns.substring(with: match.range(at: 3)))",
                              version: version, requirement: version, direct: true, dev: conf.hasPrefix("test"))
        }
    }

    private static func between(_ text: String, _ open: String, _ close: String) -> String? {
        guard let a = text.range(of: open), let b = text.range(of: close, range: a.upperBound..<text.endIndex) else { return nil }
        return text[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum GemfileLock {
    public static func parse(_ text: String) -> [Dependency] {
        var result: [Dependency] = []
        var section = ""
        var direct = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if !line.hasPrefix(" ") { section = line.trimmingCharacters(in: .whitespaces); continue }
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if section == "GEM", indent == 4, let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") {
                let name = trimmed[..<open].trimmingCharacters(in: .whitespaces)
                var version = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
                if let dash = version.firstIndex(of: "-") { version = String(version[..<dash]) }   // plateforme
                result.append(Dependency(ecosystem: .rubygems, name: name, version: version))
            } else if section == "DEPENDENCIES", indent == 2 {
                direct.insert(String(trimmed.split(separator: " ").first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "!")))
            }
        }
        return result.map { var dep = $0; dep.direct = direct.contains(dep.name); if dep.direct { dep.requirement = dep.version }; return dep }
    }
}
