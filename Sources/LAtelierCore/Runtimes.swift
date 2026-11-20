import Foundation

/// Une version installée d'un langage.
public struct RuntimeVersion: Sendable, Hashable, Identifiable {
    public var version: String
    public var isDefault: Bool
    public var location: URL?
    public var bytes: Int64?
    /// Projets qui demandent cette version (`.nvmrc`, `.python-version`, `go.mod`…).
    public var usedBy: [String]
    public var endOfLife: Date?
    public var setDefault: CommandSpec?
    public var remove: CommandSpec?
    /// Version fournie par le système ou par Xcode : on n'y touche pas.
    public var isSystem: Bool
    /// Paquets Homebrew qui en dépendent (`brew uses --installed`) : Homebrew refuserait de la supprimer.
    public var requiredBy: [String] = []

    public init(
        version: String, isDefault: Bool = false, location: URL? = nil, bytes: Int64? = nil, usedBy: [String] = [],
        endOfLife: Date? = nil, setDefault: CommandSpec? = nil, remove: CommandSpec? = nil, isSystem: Bool = false
    ) {
        self.version = version
        self.isDefault = isDefault
        self.location = location
        self.bytes = bytes
        self.usedBy = usedBy
        self.endOfLife = endOfLife
        self.setDefault = setDefault
        self.remove = remove
        self.isSystem = isSystem
    }

    public var id: String { version }
    public func isEndOfLife(now: Date = .now) -> Bool { endOfLife.map { $0 < now } ?? false }
    /// Supprimable : ni par défaut, ni utilisée par un projet, ni système (règle n° 3).
    public var canRemove: Bool { remove != nil && !isDefault && usedBy.isEmpty && !isSystem && requiredBy.isEmpty }
}

public struct RuntimeLanguage: Sendable, Identifiable {
    public var id: String
    public var name: String
    public var short: String
    public var manager: String
    public var versions: [RuntimeVersion]
    /// Action proposée (« Installer 24 LTS », « Mettre à jour stable ») et la commande qui la fait.
    public var suggestion: (label: String, command: CommandSpec)?

    public var bytes: Int64 { versions.compactMap(\.bytes).reduce(0, +) }
}

// MARK: - Fin de vie (endoflife.date)

public struct LifeCycle: Sendable, Equatable {
    public var cycle: String
    public var eol: Date?
    public var isLTS: Bool
    public var latest: String?
}

/// Dates de fin de vie depuis endoflife.date. Seul le nom du produit sort de la machine.
public enum EndOfLife {
    public static func parse(_ data: Data) -> [LifeCycle] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return rows.compactMap { row in
            let cycle = (row["cycle"] as? String) ?? (row["cycle"] as? NSNumber)?.stringValue
            guard let cycle else { return nil }
            var eol: Date?
            if let text = row["eol"] as? String { eol = formatter.date(from: text) }
            if row["eol"] as? Bool == true { eol = .distantPast }
            let lts = (row["lts"] as? String) != nil || (row["lts"] as? Bool) == true
            return LifeCycle(cycle: cycle, eol: eol, isLTS: lts, latest: row["latest"] as? String)
        }
    }

    public static func fetch(_ product: String) async -> [LifeCycle] {
        guard let url = URL(string: "https://endoflife.date/api/\(product).json") else { return [] }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [] }
        return parse(data)
    }

    /// Cycle d'une version : « 22.20.0 » → « 22 » (Node), « 3.13.5 » → « 3.13 » (Python, Go).
    public static func cycle(of version: String, components: Int) -> String {
        UpdateGap.numericParts(version).prefix(components).map(String.init).joined(separator: ".")
    }
}

// MARK: - nvm

public enum Nvm {
    public static func root(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["NVM_DIR"] ?? "\(home)/.nvm")
    }

    /// Versions installées, sans le `v`, de la plus récente à la plus ancienne.
    public static func installed(root: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "versions/node").path)) ?? []
        return names.filter { $0.hasPrefix("v") }.map { String($0.dropFirst()) }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    }

    /// Version désignée par l'alias `default` (« 22 », « lts/* », « v20.19.5 »…).
    public static func defaultVersion(root: URL) -> String? {
        resolve("default", root: root, installed: installed(root: root), depth: 0)
    }

    static func resolve(_ alias: String, root: URL, installed: [String], depth: Int) -> String? {
        guard depth < 5 else { return nil }
        var target = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if target == "node" || target == "stable" { return installed.first }
        if target.hasPrefix("v") { target.removeFirst() }
        if UpdateGap.numericParts(target).isEmpty {
            let file = root.appending(path: "alias/\(target)")
            guard let next = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return resolve(next, root: root, installed: installed, depth: depth + 1)
        }
        return installed.first { $0 == target || $0.hasPrefix(target + ".") }
    }

    /// `nvm` est une fonction shell : on charge nvm.sh puis on lui passe les arguments tels quels.
    public static func command(_ arguments: [String], root: URL) -> CommandSpec {
        CommandSpec("/bin/bash", ["-c", "source \"$NVM_DIR/nvm.sh\" && nvm \"$@\"", "nvm"] + arguments,
                    environment: ["NVM_DIR": root.path])
    }
}

// MARK: - Analyse

/// Repère les versions de langages installées et les projets qui les demandent.
public struct RuntimeScanner: Sendable {
    public let runner: CommandRunner
    public let projects: [URL]
    public let checkRemote: Bool
    let brewPrefix: URL
    let home: String

    public init(runner: CommandRunner = CommandRunner(), projects: [URL], checkRemote: Bool = true,
                brewPrefix: URL = URL(fileURLWithPath: "/opt/homebrew"), home: String = NSHomeDirectory()) {
        self.runner = runner
        self.projects = projects
        self.checkRemote = checkRemote
        self.brewPrefix = brewPrefix
        self.home = home
    }

    public func scan() async -> [RuntimeLanguage] {
        async let nodeCycles = checkRemote ? EndOfLife.fetch("nodejs") : []
        async let pythonCycles = checkRemote ? EndOfLife.fetch("python") : []
        async let goCycles = checkRemote ? EndOfLife.fetch("go") : []
        let pins = ProjectPins.read(projects)

        var languages: [RuntimeLanguage] = []
        if let node = node(pins: pins, cycles: await nodeCycles) { languages.append(node) }
        if let python = python(pins: pins, cycles: await pythonCycles) { languages.append(python) }
        if let rust = await rust(pins: pins) { languages.append(rust) }
        if let java = java(pins: pins) { languages.append(java) }
        if let go = go(pins: pins, cycles: await goCycles) { languages.append(go) }
        if let swift = await swift(pins: pins) { languages.append(swift) }

        // Tailles mesurées en une passe, 8 dossiers à la fois.
        let urls = languages.flatMap(\.versions).compactMap(\.location)
        let sizes = await DiskUsage.measure(urls)
        // Dépendants Homebrew des versions supprimables.
        let formulas = Set(languages.flatMap(\.versions).compactMap { version -> String? in
            guard let remove = version.remove, remove.tool == "brew", remove.arguments.first == "uninstall" else { return nil }
            return remove.arguments.last
        })
        let runner = runner
        let dependents = await withTaskGroup(of: (String, [String]).self) { group in
            for formula in formulas { group.addTask { (formula, await Brew.dependents(of: formula, runner: runner)) } }
            var result: [String: [String]] = [:]
            for await (formula, users) in group { result[formula] = users }
            return result
        }
        return languages.map { language in
            var language = language
            language.versions = language.versions.map { version in
                var version = version
                if let url = version.location { version.bytes = sizes[url]?.bytes }
                if let remove = version.remove, remove.tool == "brew", let formula = remove.arguments.last {
                    version.requiredBy = dependents[formula] ?? []
                }
                return version
            }
            return language
        }
    }

    private func eol(_ version: String, _ cycles: [LifeCycle], components: Int) -> Date? {
        let cycle = EndOfLife.cycle(of: version, components: components)
        return cycles.first { $0.cycle == cycle }?.eol
    }

    private func node(pins: ProjectPins, cycles: [LifeCycle]) -> RuntimeLanguage? {
        let root = Nvm.root(home: home)
        let installed = Nvm.installed(root: root)
        guard !installed.isEmpty else { return nil }
        let current = Nvm.defaultVersion(root: root)
        let versions = installed.map { version in
            RuntimeVersion(
                version: version, isDefault: version == current,
                location: root.appending(path: "versions/node/v\(version)"),
                usedBy: pins.users(of: "node", version: version),
                endOfLife: eol(version, cycles, components: 1),
                setDefault: Nvm.command(["alias", "default", version], root: root),
                remove: Nvm.command(["uninstall", version], root: root)
            )
        }
        var suggestion: (String, CommandSpec)?
        if let lts = cycles.filter({ $0.isLTS && ($0.eol ?? .distantFuture) > .now }).max(by: { $0.cycle.compare($1.cycle, options: .numeric) == .orderedAscending }),
           !installed.contains(where: { EndOfLife.cycle(of: $0, components: 1) == lts.cycle }) {
            suggestion = ("Installer \(lts.cycle) LTS", Nvm.command(["install", "--lts"], root: root))
        }
        return RuntimeLanguage(id: "node", name: "Node.js", short: "JS", manager: "nvm", versions: versions, suggestion: suggestion)
    }

    /// Formules Homebrew versionnées (`python@3.13`) : nom → (version, dossier).
    private func kegs(prefix name: String) -> [(formula: String, version: String, url: URL)] {
        let cellar = brewPrefix.appending(path: "Cellar")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cellar.path)) ?? []
        return names.filter { $0 == name || $0.hasPrefix(name + "@") }.compactMap { formula in
            let dir = cellar.appending(path: formula)
            let versions = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            guard let version = versions.first else { return nil }
            return (formula, version, dir.appending(path: version))
        }
        .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    /// Formule pointée par `/opt/homebrew/bin/<outil>` (le lien suit `../Cellar/python@3.14/…`).
    private func linkedFormula(_ tool: String) -> String? {
        let link = brewPrefix.appending(path: "bin/\(tool)")
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return nil }
        let parts = target.split(separator: "/")
        guard let index = parts.firstIndex(of: "Cellar"), index + 1 < parts.count else { return nil }
        return String(parts[index + 1])
    }

    private func brewRemove(_ formula: String) -> CommandSpec {
        CommandSpec("brew", ["uninstall", "--formula", formula], environment: Brew.environment)
    }

    private func python(pins: ProjectPins, cycles: [LifeCycle]) -> RuntimeLanguage? {
        let kegs = kegs(prefix: "python").filter { $0.formula.hasPrefix("python@") }
        guard !kegs.isEmpty else { return nil }
        let linked = linkedFormula("python3")
        let versions = kegs.map { keg in
            RuntimeVersion(
                version: keg.version.split(separator: "_").first.map(String.init) ?? keg.version,
                isDefault: keg.formula == linked, location: keg.url,
                usedBy: pins.users(of: "python", version: keg.version),
                endOfLife: eol(keg.version, cycles, components: 2),
                remove: brewRemove(keg.formula)
            )
        }
        var suggestion: (String, CommandSpec)?
        if let newest = cycles.filter({ ($0.eol ?? .distantFuture) > .now && $0.latest != nil })
            .max(by: { $0.cycle.compare($1.cycle, options: .numeric) == .orderedAscending }),
           !versions.contains(where: { EndOfLife.cycle(of: $0.version, components: 2) == newest.cycle }) {
            suggestion = ("Installer Python \(newest.cycle)", CommandSpec("brew", ["install", "python@\(newest.cycle)"], environment: Brew.environment))
        }
        return RuntimeLanguage(id: "python", name: "Python", short: "Py", manager: "Homebrew", versions: versions, suggestion: suggestion)
    }

    private func rust(pins: ProjectPins) async -> RuntimeLanguage? {
        guard let list = try? await runner.run(CommandSpec("rustup", ["toolchain", "list"]), timeout: .seconds(10)),
              list.succeeded else { return nil }
        let rustupHome = ProcessInfo.processInfo.environment["RUSTUP_HOME"] ?? "\(home)/.rustup"
        var versions: [RuntimeVersion] = []
        for line in list.stdout where !line.isEmpty {
            let name = String(line.split(separator: " ").first ?? "")
            let channel = name.split(separator: "-").first.map(String.init) ?? name
            let dir = URL(fileURLWithPath: rustupHome).appending(path: "toolchains/\(name)")
            let rustc = try? await runner.run(CommandSpec(dir.appending(path: "bin/rustc").path, ["--version"]), timeout: .seconds(10))
            let number = rustc?.stdout.first?.split(separator: " ").dropFirst().first.map(String.init)
            versions.append(RuntimeVersion(
                version: number.map { "\(channel) \($0)" } ?? channel,
                isDefault: line.contains("default"), location: dir,
                usedBy: pins.users(of: "rust", version: channel),
                setDefault: CommandSpec("rustup", ["default", name]),
                remove: CommandSpec("rustup", ["toolchain", "uninstall", name])
            ))
        }
        guard !versions.isEmpty else { return nil }
        return RuntimeLanguage(id: "rust", name: "Rust", short: "Rs", manager: "rustup", versions: versions,
                               suggestion: ("Mettre à jour stable", CommandSpec("rustup", ["update", "stable"])))
    }

    private func java(pins: ProjectPins) -> RuntimeLanguage? {
        let kegs = kegs(prefix: "openjdk")
        guard !kegs.isEmpty else { return nil }
        let versions = kegs.map { keg in
            RuntimeVersion(
                version: keg.version.split(separator: "_").first.map(String.init) ?? keg.version,
                isDefault: keg.formula == "openjdk", location: keg.url,
                usedBy: pins.users(of: "java", version: keg.version),
                remove: brewRemove(keg.formula)
            )
        }
        return RuntimeLanguage(id: "java", name: "Java", short: "Jv", manager: "Homebrew", versions: versions, suggestion: nil)
    }

    private func go(pins: ProjectPins, cycles: [LifeCycle]) -> RuntimeLanguage? {
        let kegs = kegs(prefix: "go").filter { $0.formula == "go" || $0.formula.hasPrefix("go@") }
        guard !kegs.isEmpty else { return nil }
        let linked = linkedFormula("go")
        let versions = kegs.map { keg in
            RuntimeVersion(
                version: keg.version, isDefault: keg.formula == linked || kegs.count == 1, location: keg.url,
                usedBy: pins.users(of: "go", version: keg.version),
                endOfLife: eol(keg.version, cycles, components: 2),
                remove: brewRemove(keg.formula)
            )
        }
        return RuntimeLanguage(id: "go", name: "Go", short: "Go", manager: "Homebrew", versions: versions, suggestion: nil)
    }

    private func swift(pins: ProjectPins) async -> RuntimeLanguage? {
        guard let result = try? await runner.run(CommandSpec("/usr/bin/swift", ["--version"]), timeout: .seconds(15)) else { return nil }
        let text = (result.stdout + result.stderr).joined(separator: " ")
        guard let range = text.range(of: "Swift version ") else { return nil }
        let version = text[range.upperBound...].split(separator: " ").first.map(String.init) ?? "?"
        return RuntimeLanguage(
            id: "swift", name: "Swift", short: "Sw", manager: "Xcode",
            versions: [RuntimeVersion(version: version, isDefault: true, usedBy: pins.users(of: "swift", version: version), isSystem: true)],
            suggestion: nil
        )
    }
}

/// Versions demandées par les projets, lues dans leurs fichiers de configuration.
public struct ProjectPins: Sendable {
    /// langage → [(projet, version demandée)]
    public var pins: [String: [(project: String, version: String)]] = [:]

    public static func read(_ projects: [URL]) -> ProjectPins {
        var result = ProjectPins()
        for project in projects {
            let name = project.lastPathComponent
            func text(_ file: String) -> String? {
                try? String(contentsOf: project.appending(path: file), encoding: .utf8)
            }
            func add(_ language: String, _ raw: String?) {
                guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
                value = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
                result.pins[language, default: []].append((name, value))
            }
            add("node", text(".nvmrc") ?? text(".node-version"))
            add("python", text(".python-version"))
            add("java", text(".java-version") ?? text(".sdkmanrc").flatMap { sdk in
                sdk.split(whereSeparator: \.isNewline).first { $0.hasPrefix("java=") }.map { String($0.dropFirst(5)) }
            })
            if let toolchain = text("rust-toolchain.toml") ?? text("rust-toolchain") {
                let channel = toolchain.split(whereSeparator: \.isNewline)
                    .first { $0.contains("channel") }
                    .flatMap { $0.split(separator: "\"").dropFirst().first.map(String.init) }
                add("rust", channel ?? toolchain)
            }
            if let mod = text("go.mod") {
                add("go", mod.split(whereSeparator: \.isNewline).first { $0.hasPrefix("go ") }.map { String($0.dropFirst(3)) })
            }
            if let manifest = text("Package.swift"), let range = manifest.range(of: "swift-tools-version:") {
                add("swift", manifest[range.upperBound...].split(whereSeparator: \.isNewline).first.map(String.init))
            }
        }
        return result
    }

    /// Projets dont la version demandée correspond : « 20 » couvre 20.19.5, « 3.11 » couvre 3.11.9.
    public func users(of language: String, version: String) -> [String] {
        let installed = UpdateGap.numericParts(version)
        let channel = version.split(separator: " ").first.map(String.init) ?? version
        return (pins[language] ?? []).filter { pin in
            var wanted = pin.version.trimmingCharacters(in: .whitespaces)
            if wanted.hasPrefix("v") { wanted.removeFirst() }
            if language == "rust" { return wanted.hasPrefix(channel) || channel.hasPrefix(wanted) }
            if language == "swift" { return true }   // swift-tools-version est un minimum
            let parts = UpdateGap.numericParts(wanted)
            guard !parts.isEmpty else { return false }
            return Array(installed.prefix(parts.count)) == parts
        }
        .map(\.project)
        .sorted()
    }
}
