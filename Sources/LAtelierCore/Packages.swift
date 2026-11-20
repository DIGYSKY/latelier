import Foundation

/// D'où vient un paquet installé globalement.
public enum PackageSource: String, Sendable, CaseIterable, Codable {
    case homebrew, npm, cargo, runtimes, appStore

    public var label: String {
        switch self {
        case .homebrew: "Homebrew"
        case .npm: "npm -g"
        case .cargo: "cargo"
        case .runtimes: "Runtimes"
        case .appStore: "App Store"
        }
    }
}

/// Écart entre la version installée et la disponible. Les majeures ne sont jamais cochées par défaut.
public enum UpdateGap: String, Sendable, Comparable {
    case patch, minor, major, other

    public var label: String {
        switch self {
        case .patch: "patch"
        case .minor: "mineure"
        case .major: "majeure"
        case .other: "autre"
        }
    }

    private var rank: Int { [.patch, .minor, .other, .major].firstIndex(of: self)! }
    public static func < (a: UpdateGap, b: UpdateGap) -> Bool { a.rank < b.rank }

    /// « 3.2.0 » → « 3.4.1 » : mineure. Ignore le `v` initial et la révision Homebrew (`_1`).
    public static func between(_ from: String, _ to: String) -> UpdateGap {
        let a = numericParts(from), b = numericParts(to)
        guard !a.isEmpty, !b.isEmpty else { return .other }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return index == 0 ? .major : index == 1 ? .minor : .patch }
        }
        return .patch
    }

    static func numericParts(_ version: String) -> [Int] {
        var text = version.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") { text.removeFirst() }
        if let underscore = text.firstIndex(of: "_") { text = String(text[..<underscore]) }
        if let comma = text.firstIndex(of: ",") { text = String(text[..<comma]) }
        var parts: [Int] = []
        for piece in text.split(whereSeparator: { $0 == "." || $0 == "-" }) {
            let digits = piece.prefix { $0.isNumber }
            guard let value = Int(digits) else { break }
            parts.append(value)
            if digits.count != piece.count { break }   // « 1rc2 » : on s'arrête
        }
        return parts
    }
}

/// Un paquet installé globalement (formule, cask, paquet npm, crate, app du Mac App Store…).
public struct Package: Sendable, Hashable, Identifiable {
    public var source: PackageSource
    /// Nom passé aux commandes (`openssl@3`, `497799835` pour mas).
    public var identifier: String
    public var name: String
    public var version: String
    /// Version disponible, `nil` si à jour ou inconnue.
    public var latest: String?
    public var summary: String
    public var homepage: URL?
    public var installedAt: Date?
    /// Faux pour une dépendance installée automatiquement.
    public var onRequest: Bool
    public var isCask: Bool
    public var pinned: Bool
    /// App livrée par le paquet (cask, Mac App Store) : sert à savoir si elle est ouverte.
    public var appURL: URL?
    /// Dossier où le paquet est installé, pour la taille.
    public var location: URL?
    public var bytes: Int64?
    /// Raison pour laquelle on n'y touche pas (app ouverte, outil indispensable…).
    public var lockReason: String?
    /// Failles connues (OSV) pour la version installée : npm et cargo seulement.
    public var vulnerabilities: [Vulnerability] = []

    public init(
        source: PackageSource, identifier: String, name: String? = nil, version: String,
        latest: String? = nil, summary: String = "", homepage: URL? = nil, installedAt: Date? = nil,
        onRequest: Bool = true, isCask: Bool = false, pinned: Bool = false, appURL: URL? = nil,
        location: URL? = nil, bytes: Int64? = nil, lockReason: String? = nil
    ) {
        self.source = source
        self.identifier = identifier
        self.name = name ?? identifier
        self.version = version
        self.latest = latest
        self.summary = summary
        self.homepage = homepage
        self.installedAt = installedAt
        self.onRequest = onRequest
        self.isCask = isCask
        self.pinned = pinned
        self.appURL = appURL
        self.location = location
        self.bytes = bytes
        self.lockReason = lockReason
    }

    public var id: String { "\(source.rawValue)\(isCask ? "-cask" : ""):\(identifier)" }
    public var hasUpdate: Bool { latest != nil }
    public var gap: UpdateGap? { latest.map { UpdateGap.between(version, $0) } }
    /// Cochée par défaut : tout sauf les majeures, les épinglées et ce qui est verrouillé.
    public var selectedByDefault: Bool { hasUpdate && gap != .major && !pinned && lockReason == nil }

    /// Commande de mise à jour, affichée telle quelle dans l'aperçu.
    public var upgradeCommand: CommandSpec? {
        guard hasUpdate else { return nil }
        switch source {
        case .homebrew: return CommandSpec("brew", ["upgrade", isCask ? "--cask" : "--formula", identifier], environment: Brew.environment)
        case .npm: return CommandSpec("npm", ["install", "--global", "\(identifier)@latest"])
        case .cargo: return CommandSpec("cargo", ["install", "--locked", identifier])
        case .appStore: return CommandSpec("mas", ["upgrade", identifier])
        case .runtimes: return CommandSpec("rustup", ["update", identifier])
        }
    }

    /// Commande de désinstallation ; `nil` quand on ne sait pas le faire proprement d'ici.
    public var uninstallCommand: CommandSpec? {
        switch source {
        case .homebrew: CommandSpec("brew", ["uninstall", isCask ? "--cask" : "--formula", identifier], environment: Brew.environment)
        case .npm: CommandSpec("npm", ["uninstall", "--global", identifier])
        case .cargo: CommandSpec("cargo", ["uninstall", identifier])
        case .appStore, .runtimes: nil
        }
    }
}

// MARK: - Lecture

/// Homebrew : `brew info --json=v2 --installed` (inventaire) et `brew outdated --json=v2`.
public enum Brew {
    /// Pas de mise à jour automatique de Homebrew à chaque lecture, pas d'astuces dans la sortie.
    public static let environment = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_COLOR": "1"]

    /// Formules installées qui dépendent de `formula` (`brew uses --installed`) : Homebrew refuse alors de la désinstaller.
    public static func dependents(of formula: String, runner: CommandRunner) async -> [String] {
        guard let result = try? await runner.run(CommandSpec("brew", ["uses", "--installed", formula], environment: environment), timeout: .seconds(30)),
              result.succeeded else { return [] }
        return result.stdout.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }.filter { !$0.isEmpty }
    }

    /// Paquets « à mettre à jour » : nom (ou token de cask) → version disponible.
    public static func parseOutdated(_ data: Data) -> [String: String] {
        struct Entry: Decodable { let name: String; let current_version: String }
        struct Root: Decodable { let formulae: [Entry]?; let casks: [Entry]? }
        guard let root = try? JSONDecoder().decode(Root.self, from: data) else { return [:] }
        var result: [String: String] = [:]
        for entry in (root.formulae ?? []) + (root.casks ?? []) { result[entry.name] = entry.current_version }
        return result
    }

    public static func parseInstalled(_ data: Data, outdated: [String: String], prefix: URL = URL(fileURLWithPath: "/opt/homebrew")) -> [Package] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var packages: [Package] = []
        for formula in root["formulae"] as? [[String: Any]] ?? [] {
            guard let name = formula["name"] as? String,
                  let installed = formula["installed"] as? [[String: Any]], !installed.isEmpty else { continue }
            let linked = formula["linked_keg"] as? String
            let current = installed.first { $0["version"] as? String == linked } ?? installed.last!
            let version = current["version"] as? String ?? "?"
            let time = (current["time"] as? Double).map { Date(timeIntervalSince1970: $0) }
            packages.append(Package(
                source: .homebrew, identifier: name, version: version, latest: outdated[name],
                summary: formula["desc"] as? String ?? "",
                homepage: (formula["homepage"] as? String).flatMap(URL.init(string:)),
                installedAt: time,
                onRequest: installed.contains { $0["installed_on_request"] as? Bool == true },
                pinned: formula["pinned"] as? Bool ?? false,
                location: prefix.appending(path: "Cellar/\(name)")
            ))
        }
        for cask in root["casks"] as? [[String: Any]] ?? [] {
            guard let token = cask["token"] as? String, let version = cask["installed"] as? String else { continue }
            let app = (cask["artifacts"] as? [[String: Any]] ?? [])
                .lazy.compactMap { ($0["app"] as? [Any])?.first as? String }.first
            let appURL = app.map { URL(fileURLWithPath: "/Applications").appending(path: $0) }
            packages.append(Package(
                source: .homebrew, identifier: token,
                name: (cask["name"] as? [String])?.first ?? token,
                version: version, latest: outdated[token],
                summary: cask["desc"] as? String ?? "Cask",
                homepage: (cask["homepage"] as? String).flatMap(URL.init(string:)),
                installedAt: (cask["installed_time"] as? Double).map { Date(timeIntervalSince1970: $0) },
                isCask: true, appURL: appURL,
                location: appURL ?? prefix.appending(path: "Caskroom/\(token)")
            ))
        }
        return packages
    }
}

/// Paquets npm globaux : `npm ls -g --depth=0 --json` et `npm outdated -g --json`.
public enum NpmGlobal {
    /// npm et corepack font tourner npm lui-même : jamais désinstallés d'ici.
    static let essential: Set<String> = ["npm", "corepack"]

    public static func parse(list: Data, outdated: Data?, root: URL?) -> [Package] {
        guard let object = try? JSONSerialization.jsonObject(with: list) as? [String: Any],
              let dependencies = object["dependencies"] as? [String: [String: Any]] else { return [] }
        let latest = outdated.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String: Any]] } ?? [:]
        return dependencies.compactMap { name, info -> Package? in
            guard let version = info["version"] as? String else { return nil }
            let location = root?.appending(path: name)
            let manifest = location.flatMap { try? Data(contentsOf: $0.appending(path: "package.json")) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let newer = (latest[name]?["latest"] as? String).flatMap { $0 == version ? nil : $0 }
            let installedAt = location.flatMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate }
            return Package(
                source: .npm, identifier: name, version: version, latest: newer,
                summary: manifest?["description"] as? String ?? "",
                homepage: (manifest?["homepage"] as? String).flatMap(URL.init(string:)),
                installedAt: installedAt, location: location,
                lockReason: essential.contains(name) ? "Fait tourner npm" : nil
            )
        }
        .sorted { $0.name < $1.name }
    }
}

/// `cargo install --list` : lignes « ripgrep v14.0.3: » suivies des binaires indentés.
public enum CargoInstalled {
    public static func parse(_ lines: [String]) -> [(name: String, version: String)] {
        lines.compactMap { line in
            guard !line.hasPrefix(" "), line.hasSuffix(":") else { return nil }
            let parts = line.dropLast().split(separator: " ")
            guard parts.count >= 2, parts[1].hasPrefix("v") else { return nil }
            return (String(parts[0]), String(parts[1].dropFirst()))
        }
    }
}

/// `mas list` / `mas outdated` : « 497799835  Xcode  (16.0) » ou « (16.0 -> 16.1) ».
public enum MasApps {
    public struct Entry: Sendable, Equatable {
        public let id: String
        public let name: String
        public let version: String
        public let latest: String?
    }

    public static func parse(_ lines: [String]) -> [Entry] {
        lines.compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let open = line.lastIndex(of: "("), line.hasSuffix(")") else { return nil }
            let head = line[..<open].trimmingCharacters(in: .whitespaces)
            guard let space = head.firstIndex(of: " ") else { return nil }
            let id = String(head[..<space])
            guard Int(id) != nil else { return nil }
            let name = head[space...].trimmingCharacters(in: .whitespaces)
            let inside = line[line.index(after: open)..<line.index(before: line.endIndex)]
            let versions = inside.components(separatedBy: "->").map { $0.trimmingCharacters(in: .whitespaces) }
            return Entry(id: id, name: name, version: versions[0], latest: versions.count > 1 ? versions[1] : nil)
        }
    }
}

/// `rustup check` : « stable-aarch64-apple-darwin - update available: 1.94.0 (…) -> 1.100.0 (…) ».
public enum RustupCheck {
    public static func parse(_ lines: [String]) -> [Package] {
        lines.compactMap { line in
            guard let dash = line.range(of: " - ") else { return nil }
            let toolchain = String(line[..<dash.lowerBound])
            let channel = toolchain.split(separator: "-").first.map(String.init) ?? toolchain
            let rest = line[dash.upperBound...]
            let versions = rest.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
            let sides = versions.components(separatedBy: "->").map {
                $0.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            }
            guard let current = sides.first, !current.isEmpty else { return nil }
            let available = rest.lowercased().contains("update available") && sides.count > 1 ? sides[1] : nil
            return Package(source: .runtimes, identifier: channel, name: "Rust \(channel)", version: current,
                           latest: available, summary: "via rustup")
        }
    }
}

// MARK: - Analyse

/// Interroge toutes les sources installées, en parallèle. Une source absente est simplement ignorée ;
/// une source qui échoue est signalée dans `problems`.
public struct PackageScanner: Sendable {
    public struct Result: Sendable {
        public var packages: [Package]
        /// Sources présentes sur la machine.
        public var sources: Set<PackageSource>
        public var problems: [String]
    }

    public let runner: CommandRunner
    /// Bundle IDs ou chemins des apps ouvertes : leur mise à jour attend qu'elles soient quittées.
    public let openApps: Set<String>
    public let checkRemote: Bool

    public init(runner: CommandRunner = CommandRunner(), openApps: Set<String> = [], checkRemote: Bool = true) {
        self.runner = runner
        self.openApps = openApps
        self.checkRemote = checkRemote
    }

    public func scan() async -> Result {
        async let brew = homebrew()
        async let npm = npmGlobal()
        async let cargo = cargoCrates()
        async let mas = appStore()
        async let rust = rustup()
        let parts = await [brew, npm, cargo, mas, rust]

        var result = Result(packages: [], sources: [], problems: [])
        for part in parts {
            guard let part else { continue }
            result.sources.insert(part.source)
            result.packages += part.packages
            if let problem = part.problem { result.problems.append(problem) }
        }
        result.packages = result.packages.map(lockIfOpen)
        if checkRemote { await addVulnerabilities(&result) }
        return result
    }

    /// Une requête OSV pour les paquets npm -g et cargo (noms et versions seulement).
    private func addVulnerabilities(_ result: inout Result) async {
        let ecosystems: [PackageSource: Ecosystem] = [.npm: .npm, .cargo: .cargo]
        let deps = result.packages.compactMap { package in
            ecosystems[package.source].map { Dependency(ecosystem: $0, name: package.identifier, version: package.version, direct: true) }
        }
        guard !deps.isEmpty else { return }
        do {
            let found = try await OSVClient().vulnerabilities(of: deps)
            result.packages = result.packages.map { package in
                guard let ecosystem = ecosystems[package.source] else { return package }
                var package = package
                package.vulnerabilities = found[Dependency(ecosystem: ecosystem, name: package.identifier, version: package.version).versionKey] ?? []
                return package
            }
        } catch {
            result.problems.append(error.localizedDescription)
        }
    }

    private struct Part: Sendable {
        let source: PackageSource
        var packages: [Package] = []
        var problem: String?
    }

    private func lockIfOpen(_ package: Package) -> Package {
        guard let app = package.appURL, openApps.contains(app.standardizedFileURL.path) else { return package }
        var package = package
        package.lockReason = String(localized: "App ouverte")
        return package
    }

    private func output(_ spec: CommandSpec, timeout: Duration = .seconds(60)) async -> CommandResult? {
        guard runner.locator.locate(spec.tool) != nil else { return nil }
        return try? await runner.run(spec, timeout: timeout)
    }

    private func data(_ result: CommandResult?) -> Data? {
        result.map { Data($0.stdout.joined(separator: "\n").utf8) }
    }

    private func homebrew() async -> Part? {
        guard let brew = runner.locator.locate("brew") else { return nil }
        async let info = output(CommandSpec(brew.path, ["info", "--json=v2", "--installed"], environment: Brew.environment))
        async let outdated = output(CommandSpec(brew.path, ["outdated", "--json=v2"], environment: Brew.environment))
        let (infoResult, outdatedResult) = await (info, outdated)
        var part = Part(source: .homebrew)
        guard let infoResult, infoResult.succeeded, let infoData = data(infoResult) else {
            part.problem = String(localized: "Homebrew n’a pas répondu (brew info).")
            return part
        }
        let prefix = brew.deletingLastPathComponent().deletingLastPathComponent()
        let newer = data(outdatedResult).map(Brew.parseOutdated) ?? [:]
        if outdatedResult?.succeeded != true { part.problem = String(localized: "Impossible de lire les mises à jour Homebrew.") }
        part.packages = Brew.parseInstalled(infoData, outdated: newer, prefix: prefix)
        return part
    }

    private func npmGlobal() async -> Part? {
        guard let npm = runner.locator.locate("npm") else { return nil }
        async let list = output(CommandSpec(npm.path, ["ls", "--global", "--depth=0", "--json"]))
        // `npm outdated` sort avec le code 1 quand il y a des mises à jour : on lit quand même.
        async let outdated = checkRemote ? output(CommandSpec(npm.path, ["outdated", "--global", "--json"])) : nil
        async let root = output(CommandSpec(npm.path, ["root", "--global"]))
        let (listResult, outdatedResult, rootResult) = await (list, outdated, root)
        var part = Part(source: .npm)
        guard let listData = data(listResult) else {
            part.problem = String(localized: "npm n’a pas répondu.")
            return part
        }
        let rootURL = rootResult?.stdout.first.map { URL(fileURLWithPath: $0) }
        part.packages = NpmGlobal.parse(list: listData, outdated: data(outdatedResult), root: rootURL)
        return part
    }

    private func cargoCrates() async -> Part? {
        guard let result = await output(CommandSpec("cargo", ["install", "--list"])) else { return nil }
        var part = Part(source: .cargo)
        let crates = CargoInstalled.parse(result.stdout)
        let latest = checkRemote ? await CratesIO.latestVersions(crates.map(\.name)) : [:]
        let home = ProcessInfo.processInfo.environment["CARGO_HOME"] ?? NSHomeDirectory() + "/.cargo"
        part.packages = crates.map { crate in
            let newer = latest[crate.name].flatMap { $0 == crate.version ? nil : $0 }
            return Package(source: .cargo, identifier: crate.name, version: crate.version, latest: newer,
                           location: URL(fileURLWithPath: home).appending(path: "bin/\(crate.name)"))
        }
        return part
    }

    private func appStore() async -> Part? {
        guard let list = await output(CommandSpec("mas", ["list"])) else { return nil }
        let outdated = checkRemote ? await output(CommandSpec("mas", ["outdated"])) : nil
        let newer = Dictionary(MasApps.parse(outdated?.stdout ?? []).map { ($0.id, $0.latest) }, uniquingKeysWith: { a, _ in a })
        var part = Part(source: .appStore)
        part.packages = MasApps.parse(list.stdout).map { app in
            let url = URL(fileURLWithPath: "/Applications/\(app.name).app")
            return Package(source: .appStore, identifier: app.id, name: app.name, version: app.version,
                           latest: newer[app.id] ?? nil, summary: "Mac App Store", appURL: url, location: url)
        }
        return part
    }

    private func rustup() async -> Part? {
        guard checkRemote, let result = await output(CommandSpec("rustup", ["check"]), timeout: .seconds(30)) else { return nil }
        var part = Part(source: .runtimes)
        part.packages = RustupCheck.parse(result.stdout)
        if !result.succeeded && part.packages.isEmpty { part.problem = String(localized: "rustup check a échoué (réseau ?).") }
        return part
    }
}

/// Dernières versions publiées sur crates.io (seuls les noms de crates sortent de la machine).
enum CratesIO {
    static func latestVersions(_ names: [String]) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self) { group in
            for name in names {
                group.addTask {
                    guard let url = URL(string: "https://crates.io/api/v1/crates/\(name)") else { return (name, nil) }
                    var request = URLRequest(url: url, timeoutInterval: 15)
                    request.setValue("LAtelier (macOS)", forHTTPHeaderField: "User-Agent")
                    guard let (data, _) = try? await URLSession.shared.data(for: request),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let crate = object["crate"] as? [String: Any] else { return (name, nil) }
                    return (name, crate["max_stable_version"] as? String)
                }
            }
            var result: [String: String] = [:]
            for await (name, version) in group { if let version { result[name] = version } }
            return result
        }
    }
}

// MARK: - Plans

public enum PackagePlans {
    /// Une étape par paquet : si l'une échoue, les autres continuent et l'échec est signalé.
    public static func upgrade(_ packages: [Package]) -> ActionPlan? {
        let ready = packages.filter { $0.lockReason == nil && $0.upgradeCommand != nil }
        let skipped = packages.filter { $0.lockReason != nil }.map { "\($0.name) : \($0.lockReason!)" }
        guard !ready.isEmpty else { return nil }
        let majors = ready.filter { $0.gap == .major }.count
        var summary = ready.count == 1
            ? "\(ready[0].name) \(ready[0].version) → \(ready[0].latest ?? "?")."
            : String(localized: "\(ready.count) paquets, un par un. Si l’un échoue, les autres continuent.")
        if majors > 0 { summary += String(localized: " Dont \(majors) mise(s) à jour majeure(s) : vérifie les changements incompatibles.") }
        return ActionPlan(
            title: ready.count == 1 ? String(localized: "Mettre à jour \(ready[0].name)") : String(localized: "Mettre à jour \(ready.count) paquets"),
            summary: summary, kind: .paquet, risk: majors > 0 ? .caution : .safe, reversible: false,
            steps: ready.compactMap(\.upgradeCommand).map(ActionStep.command),
            skipped: skipped, stopOnFailure: false
        )
    }

    public static func uninstall(_ package: Package) -> ActionPlan? {
        guard package.lockReason == nil, let command = package.uninstallCommand else { return nil }
        let size = package.bytes.map { String(localized: " Libère environ \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)).") } ?? ""
        return ActionPlan(
            title: String(localized: "Désinstaller \(package.name)"),
            summary: String(localized: "\(package.source.label) · \(package.version).\(size) Réinstallable à tout moment."),
            kind: .paquet, risk: .caution, reversible: false,
            steps: [.command(command)], estimatedBytes: package.bytes
        )
    }
}
