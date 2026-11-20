import Foundation

// MARK: - Résultats

/// Une faille connue dans une dépendance d'un projet (ou dans un paquet global).
public struct VulnerabilityFinding: Sendable, Identifiable, Hashable {
    /// `nil` : paquet installé globalement (npm -g, cargo install).
    public var project: URL?
    public var projectName: String
    /// Fichier d'où vient la version (`yarn.lock`, `Cargo.lock`…).
    public var file: String
    public var manager: PackageManager?
    public var dependency: Dependency
    public var vulnerability: Vulnerability
    public var fixedVersion: String?
    /// Paquets qui demandent cette version (dépendance indirecte).
    public var requiredBy: [DependencyRequirement] = []
    /// Toutes les versions de ce paquet présentes dans le lockfile.
    public var lockedVersions: [String] = []

    public var id: String { "\(projectName)|\(file)|\(dependency.versionKey)|\(vulnerability.id)" }
    public var severity: Severity { vulnerability.severity }
}

/// Toutes les failles d'un paquet dans un projet : une ligne, une commande de correction.
public struct VulnerablePackage: Sendable, Identifiable, Hashable {
    public var project: URL?
    public var projectName: String
    public var file: String
    public var manager: PackageManager?
    public var dependency: Dependency
    public var findings: [VulnerabilityFinding]
    /// Paquets qui demandent cette version : vide pour une dépendance directe.
    public var requiredBy: [DependencyRequirement] { findings.first?.requiredBy ?? [] }
    public var lockedVersions: [String] { findings.first?.lockedVersions ?? [] }

    public var id: String { "\(project?.path ?? projectName)|\(file)|\(dependency.versionKey)" }

    /// Parents dont l'intervalle exclut la version corrigée : une simple mise à jour ne peut pas l'installer.
    public var blockers: [DependencyRequirement] {
        guard !dependency.direct, let fixed = fixedVersion else { return [] }
        return requiredBy.filter { requirement in
            requirement.range.flatMap { SemverRange.satisfies(fixed, $0) } == false
        }
    }
    public var severity: Severity { findings.map(\.severity).max() ?? .unknown }
    /// Version qui corrige toutes les failles connues ; `nil` si l'une n'a pas encore de correctif.
    public var fixedVersion: String? {
        let fixes = findings.map(\.fixedVersion)
        guard !fixes.isEmpty, !fixes.contains(nil) else { return nil }
        return fixes.compactMap { $0 }.max { VersionOrder.compare($0, $1) == .orderedAscending }
    }
    /// La faille la plus grave, pour le titre.
    public var headline: VulnerabilityFinding { findings.max { $0.severity < $1.severity }! }
}

/// Un secret repéré dans les fichiers suivis par git.
public struct SecretFinding: Sendable, Identifiable, Hashable {
    public var project: URL
    /// Chemin relatif au dépôt.
    public var file: String
    public var line: Int?
    /// « Clé AWS », « Fichier .env suivi par git »…
    public var kind: String
    /// Extrait masqué (« AKIA••••••••3F7Q ») ou noms des variables sensibles.
    public var detail: String
    public var isEnvFile: Bool
    /// Faux : `.env` suivi mais sans valeur sensible (rangé dans l'hygiène).
    public var sensitive = true

    public var id: String { "\(project.path)|\(file)|\(line ?? 0)|\(kind)" }
    public var projectName: String { project.lastPathComponent }
}

/// Un runtime en fin de vie demandé par des projets (`.nvmrc`, `.python-version`).
public struct EndOfLifePin: Sendable, Identifiable, Hashable {
    public struct Use: Sendable, Hashable {
        public var project: String
        public var file: String
    }

    public var language: String
    public var cycle: String
    public var endOfLife: Date
    public var uses: [Use]

    public var id: String { "\(language) \(cycle)" }
}

public struct Hygiene: Sendable {
    /// Dépôts sans remote : rien n'est sauvegardé ailleurs.
    public var withoutRemote: [String] = []
    /// Projets avec des dépendances mais sans lockfile : versions non reproductibles.
    public var withoutLockfile: [(project: String, manifest: String)] = []
    /// Projets avec deux lockfiles du même écosystème (npm + yarn).
    public var duplicateLockfiles: [(project: String, files: [String])] = []
    /// `.env` suivis par git, sans valeur sensible repérée : à sortir du dépôt quand même.
    public var trackedEnvFiles: [SecretFinding] = []

    public var isEmpty: Bool { withoutRemote.isEmpty && withoutLockfile.isEmpty && duplicateLockfiles.isEmpty && trackedEnvFiles.isEmpty }
}

/// Une bibliothèque, toutes versions et tous projets confondus (page Dépendances).
public struct Library: Sendable, Identifiable {
    public struct Use: Sendable, Hashable, Identifiable {
        public var project: URL
        public var manifest: String
        public var manager: PackageManager
        public var version: String
        public var requirement: String?
        public var dev: Bool
        public var gap: UpdateGap?

        public var id: String { "\(project.path)#\(manifest)" }
        public var projectName: String { project.lastPathComponent }
    }

    public var ecosystem: Ecosystem
    public var name: String
    public var latest: String?
    public var license: String?
    public var uses: [Use]
    public var worstSeverity: Severity?

    public var id: String { "\(ecosystem.rawValue):\(name)" }
    public var outdated: [Use] { uses.filter { $0.gap != nil } }
    public var versionCount: Int { Set(uses.map(\.version)).count }
}

public struct ProjectAnalysis: Sendable {
    public var manifests: [ProjectManifest] = []
    public var registry: [String: RegistryInfo] = [:]
    public var vulnerabilities: [VulnerabilityFinding] = []
    public var secrets: [SecretFinding] = []
    public var endOfLife: [EndOfLifePin] = []
    public var hygiene = Hygiene()
    public var problems: [String] = []
    public var projectCount = 0
    public var checkedAt = Date()

    public init() {}

    /// Dépendances directes regroupées par bibliothèque.
    public var libraries: [Library] {
        var groups: [String: Library] = [:]
        let worst = Dictionary(grouping: vulnerabilities.filter { $0.project != nil }) { $0.dependency.libraryKey }
            .mapValues { $0.map(\.severity).max() }
        for manifest in manifests {
            for dep in manifest.direct {
                let key = dep.libraryKey
                let info = registry[key]
                var library = groups[key] ?? Library(
                    ecosystem: dep.ecosystem, name: dep.name, latest: info?.latest,
                    license: dep.license ?? info?.license, uses: [], worstSeverity: worst[key] ?? nil
                )
                if library.license == nil { library.license = dep.license }
                var gap: UpdateGap?
                if let latest = info?.latest, !dep.version.isEmpty,
                   VersionOrder.compare(dep.version, latest) == .orderedAscending {
                    gap = UpdateGap.between(dep.version, latest)
                }
                library.uses.append(.init(project: manifest.project, manifest: manifest.manifest, manager: manifest.manager,
                                          version: dep.version, requirement: dep.requirement, dev: dep.dev, gap: gap))
                groups[key] = library
            }
        }
        return groups.values.sorted { a, b in
            (b.uses.count, a.name.lowercased()) < (a.uses.count, b.name.lowercased())
        }
    }

    /// Failles regroupées par paquet et par projet, les plus graves d'abord, les dépendances directes avant.
    public var vulnerablePackages: [VulnerablePackage] {
        let groups = Dictionary(grouping: vulnerabilities) { "\($0.project?.path ?? $0.projectName)|\($0.file)|\($0.dependency.versionKey)" }
        return groups.values.map { findings in
            let first = findings[0]
            return VulnerablePackage(project: first.project, projectName: first.projectName, file: first.file,
                                     manager: first.manager, dependency: first.dependency,
                                     findings: findings.sorted { $0.severity > $1.severity })
        }
        .sorted { a, b in
            (a.severity.rawValue, a.dependency.direct ? 1 : 0, b.projectName, b.dependency.name)
                > (b.severity.rawValue, b.dependency.direct ? 1 : 0, a.projectName, a.dependency.name)
        }
    }

    /// Nombre de failles par projet (liste des dépôts, filtre « vulnérables »).
    public func vulnerabilityCount(project: URL) -> Int {
        vulnerabilities.filter { $0.project == project }.count
    }
}

// MARK: - Secrets

public enum SecretScanner {
    /// Motifs reconnus. Le premier groupe est volontairement absent : on masque tout l'extrait.
    static let patterns: [(kind: String, regex: String)] = [
        (String(localized: "Clé AWS"), "AKIA[0-9A-Z]{16}"),
        (String(localized: "Jeton GitHub"), "gh[pousr]_[A-Za-z0-9]{36,}"),
        (String(localized: "Jeton GitHub"), "github_pat_[A-Za-z0-9_]{60,}"),
        (String(localized: "Jeton GitLab"), "glpat-[A-Za-z0-9_-]{20,}"),
        (String(localized: "Clé Anthropic"), "sk-ant-[A-Za-z0-9_-]{20,}"),
        (String(localized: "Clé OpenAI"), "sk-(proj-)?[A-Za-z0-9_-]{40,}"),
        (String(localized: "Jeton Slack"), "xox[abprs]-[A-Za-z0-9-]{10,}"),
        (String(localized: "Clé Stripe"), "[rs]k_live_[A-Za-z0-9]{20,}"),
        (String(localized: "Clé Google"), "AIza[A-Za-z0-9_-]{35}"),
        (String(localized: "Jeton Discord"), "[MN][A-Za-z0-9]{23,25}\\.[A-Za-z0-9_-]{6}\\.[A-Za-z0-9_-]{27,}"),
        (String(localized: "Clé privée"), "-----BEGIN ([A-Z]+ )?PRIVATE KEY-----"),
    ]

    /// Fichiers ignorés : lockfiles, code minifié, et jeux de test (clés factices).
    static let excluded = [
        "**/*.lock", "**/package-lock.json", "**/*.min.js", "**/*.map", "**/*.svg", "**/.pnp.cjs", "**/.pnp.loader.mjs",
        "**/.yarn/**", "**/test/**", "**/tests/**", "**/testdata/**", "**/fixtures/**", "**/__tests__/**", "**/__fixtures__/**",
    ]

    /// Noms de variables d'un `.env` qui ressemblent à des secrets.
    static let sensitiveNames = ["KEY", "SECRET", "TOKEN", "PASSWORD", "PASSWD", "PWD", "PASS", "CREDENTIAL", "PRIVATE", "DSN", "AUTH"]

    public static func scan(repo: URL, runner: CommandRunner) async -> [SecretFinding] {
        var findings: [SecretFinding] = []
        // 1. Fichiers .env suivis par git
        if let files = try? await runner.run(CommandSpec("git", ["-C", repo.path, "ls-files"]), timeout: .seconds(20)), files.succeeded {
            for path in files.stdout where isEnvFile(path) {
                let text = (try? String(contentsOf: repo.appending(path: path), encoding: .utf8)) ?? ""
                let names = sensitiveVariables(in: text)
                findings.append(SecretFinding(
                    project: repo, file: path, line: nil, kind: String(localized: "Fichier .env suivi par git"),
                    detail: names.prefix(4).joined(separator: ", ") + (names.count > 4 ? "…" : ""),
                    isEnvFile: true, sensitive: !names.isEmpty
                ))
            }
        }
        // 2. Motifs de clés dans les fichiers suivis (contenu actuel, pas l'historique)
        var arguments = ["-C", repo.path, "grep", "-I", "-n", "-E", "--max-count=3"]
        for pattern in patterns { arguments += ["-e", pattern.regex] }
        arguments += ["--", "."] + excluded.map { ":(exclude,glob)\($0)" }
        if let result = try? await runner.run(CommandSpec("git", arguments), timeout: .seconds(30)) {
            for line in result.stdout.prefix(200) {
                if let finding = parseGrep(line, repo: repo), !findings.contains(where: { $0.file == finding.file && $0.isEnvFile }) {
                    findings.append(finding)
                }
            }
        }
        return Array(findings.prefix(20))
    }

    static func isEnvFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        guard name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env") else { return false }
        return !["example", "exemple", "sample", "template", "dist", "defaults", "schema", "tpl", "test"].contains { name.hasSuffix(".\($0)") || name.hasSuffix("-\($0)") }
    }

    static func sensitiveVariables(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equal = line.firstIndex(of: "=") else { return nil }
            let name = line[..<equal].replacingOccurrences(of: "export ", with: "").trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equal)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            guard !value.isEmpty, value.count >= 6, !value.hasPrefix("${"), !["changeme", "xxx", "your_", "<"].contains(where: value.lowercased().hasPrefix) else { return nil }
            let upper = name.uppercased()
            return sensitiveNames.contains(where: upper.contains) ? name : nil
        }
    }

    /// « src/config.ts:12:const key = "AKIA…" » → constat, extrait masqué.
    static func parseGrep(_ line: String, repo: URL) -> SecretFinding? {
        let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let number = Int(parts[1]) else { return nil }
        let content = String(parts[2])
        for pattern in patterns {
            guard let range = content.range(of: pattern.regex, options: .regularExpression) else { continue }
            return SecretFinding(project: repo, file: String(parts[0]), line: number, kind: pattern.kind,
                                 detail: mask(String(content[range])), isEnvFile: false)
        }
        return nil
    }

    /// Ne montre que le début et la fin : « AKIA••••••••3F7Q ».
    public static func mask(_ secret: String) -> String {
        if secret.hasPrefix("-----BEGIN") { return secret }
        guard secret.count > 10 else { return String(repeating: "•", count: secret.count) }
        return secret.prefix(4) + String(repeating: "•", count: 8) + secret.suffix(4)
    }

    /// Ne plus suivre le fichier et l'ajouter au .gitignore. La clé reste dans l'historique : à changer.
    public static func untrackPlan(_ finding: SecretFinding) -> ActionPlan {
        ActionPlan(
            title: String(localized: "Ne plus suivre \(finding.file) dans \(finding.projectName)"),
            summary: String(localized: "Le fichier reste sur le disque mais sort du dépôt au prochain commit, et il est ajouté au .gitignore. Il reste dans l’historique git : changez les clés concernées chez leurs fournisseurs."),
            kind: .git, risk: .caution, reversible: true,
            steps: [
                .command(CommandSpec("git", ["rm", "--cached", "--", finding.file], in: finding.project)),
                .appendLine("/" + finding.file, to: finding.project.appending(path: ".gitignore")),
            ]
        )
    }
}

// MARK: - Fin de vie

public enum EndOfLifePins {
    /// Projets qui fixent une version de Node ou Python arrivée en fin de vie.
    public static func find(projects: [URL], node: [LifeCycle], python: [LifeCycle], now: Date = .now) -> [EndOfLifePin] {
        var result: [String: EndOfLifePin] = [:]
        for project in projects {
            func text(_ file: String) -> String? {
                (try? String(contentsOf: project.appending(path: file), encoding: .utf8))?
                    .split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
            }
            let checks: [(String, [String], [LifeCycle], Int)] = [
                ("Node.js", [".nvmrc", ".node-version"], node, 1),
                ("Python", [".python-version"], python, 2),
            ]
            for (language, files, cycles, components) in checks {
                guard let file = files.first(where: { text($0) != nil }), let raw = text(file) else { continue }
                let cycle = EndOfLife.cycle(of: raw, components: components)
                guard !cycle.isEmpty, let eol = cycles.first(where: { $0.cycle == cycle })?.eol, eol < now else { continue }
                let key = "\(language) \(cycle)"
                var pin = result[key] ?? EndOfLifePin(language: language, cycle: cycle, endOfLife: eol, uses: [])
                pin.uses.append(.init(project: project.lastPathComponent, file: file))
                result[key] = pin
            }
        }
        return result.values.sorted { $0.id < $1.id }
    }
}

// MARK: - Commandes de mise à jour

public enum DependencyFix {
    /// Passe une dépendance directe à `version` (ou plus) avec l'outil du projet.
    public static func upgradeDirect(_ name: String, to version: String, dev: Bool, manager: PackageManager, in project: URL) -> CommandSpec? {
        let caret = "^\(version)"
        let args: [String]
        let tool: String
        switch manager {
        case .npm: (tool, args) = ("npm", ["install", "\(name)@\(caret)"] + (dev ? ["--save-dev"] : []))
        case .yarn: (tool, args) = ("yarn", ["add", "\(name)@\(caret)"] + (dev ? ["--dev"] : []))
        case .yarnBerry: (tool, args) = ("yarn", ["up", "\(name)@\(caret)"])
        case .pnpm: (tool, args) = ("pnpm", ["add", "\(name)@\(caret)"] + (dev ? ["--save-dev"] : []))
        case .bun: (tool, args) = ("bun", ["add", "\(name)@\(caret)"] + (dev ? ["--dev"] : []))
        case .cargo: (tool, args) = ("cargo", ["add", "\(name)@\(version)"] + (dev ? ["--dev"] : []))
        case .uv: (tool, args) = ("uv", ["add", "\(name)>=\(version)"] + (dev ? ["--dev"] : []))
        case .poetry: (tool, args) = ("poetry", ["add", "\(name)@\(caret)"] + (dev ? ["--group", "dev"] : []))
        case .go: (tool, args) = ("go", ["get", "\(name)@\(version.hasPrefix("v") ? version : "v" + version)"])
        case .composer: (tool, args) = ("composer", ["require", "\(name):\(caret)"] + (dev ? ["--dev"] : []))
        case .bundler: (tool, args) = ("bundle", ["update", "--conservative", name])
        case .pip, .swiftpm, .maven, .gradle: return nil
        }
        return CommandSpec(tool, args, in: project)
    }

    /// Corrige une faille : dépendance directe → nouvelle exigence ; transitive → mise à jour dans le lockfile.
    public static func fix(_ dep: Dependency, to fixed: String, manager: PackageManager, in project: URL) -> CommandSpec? {
        if dep.direct { return upgradeDirect(dep.name, to: fixed, dev: dep.dev, manager: manager, in: project) }
        let name = dep.name
        let spec: (String, [String])? = switch manager {
        case .npm: ("npm", ["update", name])
        case .yarn: ("yarn", ["upgrade", name])
        case .yarnBerry: ("yarn", ["up", "-R", name])
        case .pnpm: ("pnpm", ["update", "--depth", "Infinity", name])
        case .bun: ("bun", ["update", name])
        case .cargo: ("cargo", ["update", "-p", "\(name)@\(dep.version)", "--precise", fixed])
        case .uv: ("uv", ["lock", "--upgrade-package", name])
        case .poetry: ("poetry", ["update", name])
        case .go: ("go", ["get", "\(name)@\(fixed.hasPrefix("v") ? fixed : "v" + fixed)"])
        case .composer: ("composer", ["update", "--with-dependencies", name])
        case .bundler: ("bundle", ["update", "--conservative", name])
        case .swiftpm: ("swift", ["package", "update", String(name.split(separator: "/").last ?? "")])
        case .pip, .maven, .gradle: nil
        }
        return spec.map { CommandSpec($0.0, $0.1, in: project) }
    }

    public static func fix(_ finding: VulnerabilityFinding) -> CommandSpec? {
        guard let project = finding.project, let manager = finding.manager, let fixed = finding.fixedVersion else { return nil }
        return fix(finding.dependency, to: fixed, manager: manager, in: project)
    }

    /// Mise à jour par commande ; `nil` si un parent l'empêche, ou pour un sous-paquet yarn 1 (voir `canRelock`).
    public static func fix(_ package: VulnerablePackage) -> CommandSpec? {
        guard let project = package.project, let manager = package.manager, let fixed = package.fixedVersion,
              package.blockers.isEmpty, !canRelock(package) else { return nil }
        return fix(package.dependency, to: fixed, manager: manager, in: project)
    }

    /// Sous-paquet yarn 1 que ses parents laissent monter : `yarn upgrade` ne fait rien pour un sous-paquet,
    /// on retire son entrée du yarn.lock puis `yarn install` la re-résout.
    public static func canRelock(_ package: VulnerablePackage) -> Bool {
        package.manager == .yarn && !package.dependency.direct && package.project != nil
            && package.fixedVersion != nil && package.blockers.isEmpty && package.file == "yarn.lock"
    }

    /// Bloquée par un parent, mais la version peut être forcée dans `package.json` (overrides / resolutions).
    public static func canForce(_ package: VulnerablePackage) -> Bool {
        guard package.project != nil, let manager = package.manager, DependencyOverride.field(for: manager) != nil,
              let fixed = package.fixedVersion, !package.blockers.isEmpty else { return false }
        // Le forçage vaut pour tous les exemplaires du paquet : seulement s'ils sont de la même série.
        return package.lockedVersions.allSatisfy { compatible($0, fixed) }
    }

    public static func canFix(_ package: VulnerablePackage) -> Bool { fix(package) != nil || canRelock(package) || canForce(package) }

    /// Outil lancé par la correction (pour vérifier qu'il est installé).
    public static func tool(for package: VulnerablePackage) -> String? {
        if canRelock(package) || canForce(package), let project = package.project, let manager = package.manager {
            return DependencyOverride.install(for: manager, in: project)?.tool
        }
        return fix(package)?.tool
    }

    /// Pourquoi rien n'est proposé pour un paquet bloqué par ses parents.
    public static func blockedReason(_ package: VulnerablePackage) -> String? {
        guard !package.blockers.isEmpty, !canForce(package) else { return nil }
        let parents = package.blockers.map(\.label).joined(separator: ", ")
        if let manager = package.manager, DependencyOverride.field(for: manager) == nil {
            return String(localized: "Demandé par \(parents) : mettez ce paquet à jour, ou forcez la version à la main (\(manager.label)).")
        }
        return String(localized: "Demandé par \(parents). D’autres versions de \(package.dependency.name) sont utilisées dans le projet : forcer une seule version risquerait de les casser. Mettez à jour le paquet parent.")
    }

    /// Même version majeure (même mineure pour les 0.x) : forcer l'une vers l'autre reste compatible.
    static func compatible(_ a: String, _ b: String) -> Bool {
        let x = UpdateGap.numericParts(a), y = UpdateGap.numericParts(b)
        guard let first = x.first, first == y.first else { return false }
        return first > 0 || (x.count > 1 && y.count > 1 && x[1] == y[1])
    }

    /// Une commande par paquet vulnérable ; si l'une échoue, les autres continuent.
    /// Sous-paquets : entrée retirée du yarn.lock (yarn 1) ou version forcée dans `package.json`, puis réinstallation.
    /// Après coup, le lockfile est relu : une version restée vulnérable est signalée.
    public static func fixPlan(_ packages: [VulnerablePackage]) -> ActionPlan? {
        struct Group {
            var manager: PackageManager
            var forced: [(String, String)] = []
            var relock: [(String, String)] = []
            var notes: [String] = []
        }
        var seen = Set<String>()
        var commands: [CommandSpec] = []
        var skipped: [String] = []
        var groups: [URL: Group] = [:]
        var expected: [DependencyExpectation] = []
        var planned: [VulnerablePackage] = []
        for package in packages {
            if let project = package.project, let manager = package.manager, let fixed = package.fixedVersion,
               canForce(package) || canRelock(package) {
                var group = groups[project] ?? Group(manager: manager)
                if canForce(package) {
                    if !group.forced.contains(where: { $0.0 == package.dependency.name }) {
                        group.forced.append((package.dependency.name, "^\(fixed)"))
                    }
                    group.notes.append("\(package.dependency.name) (" + package.blockers.map(\.label).joined(separator: ", ") + ")")
                } else {
                    group.relock.append((package.dependency.name, package.dependency.version))
                }
                groups[project] = group
                planned.append(package)
                continue
            }
            guard let command = fix(package) else {
                let reason = blockedReason(package)
                    ?? (package.fixedVersion == nil ? String(localized: "pas encore de version corrigée") : String(localized: "\(package.file) à modifier à la main"))
                skipped.append("\(package.dependency.name) (\(package.projectName)) : " + reason)
                continue
            }
            planned.append(package)
            if seen.insert(command.displayString).inserted { commands.append(command) }
        }
        // Les modifications de fichiers d'abord : elles vérifient que le fichier n'a pas changé depuis l'aperçu.
        var edits: [ActionStep] = []
        var installs: [CommandSpec] = []
        var notes: [String] = []
        var dropped = Set<String>()
        for (project, group) in groups.sorted(by: { $0.key.path < $1.key.path }) {
            var changed = false
            if !group.forced.isEmpty, let field = DependencyOverride.field(for: group.manager) {
                let file = project.appending(path: "package.json")
                if let before = try? String(contentsOf: file, encoding: .utf8) {
                    var after = before
                    var added: [String] = []
                    for (name, value) in group.forced {
                        if let next = DependencyOverride.set(name, to: value, field: field, in: after) {
                            after = next
                            added.append("\"\(field)\" › \"\(name)\": \"\(value)\"")
                        } else {
                            dropped.insert("\(project.path)|\(name)")
                            skipped.append(String(localized: "\(name) (\(project.lastPathComponent)) : le bloc « \(field) » de package.json est à modifier à la main"))
                        }
                    }
                    if after != before {
                        edits.append(.editFile(FileEdit(file: file, before: before, after: after, added: added)))
                        changed = true
                        notes.append(group.notes.count == 1
                            ? String(localized: "Sous-paquet bloqué par la version que demande son parent : \(group.notes[0]). Sa version est forcée dans « \(field) » de package.json.")
                            : String(localized: "Sous-paquets bloqués par la version que demandent leurs parents : \(group.notes.joined(separator: ", ")). Leurs versions sont forcées dans « \(field) » de package.json."))
                    }
                } else {
                    for (name, _) in group.forced { dropped.insert("\(project.path)|\(name)") }
                    skipped.append(String(localized: "\(project.lastPathComponent) : package.json illisible"))
                }
            }
            if !group.relock.isEmpty {
                let file = project.appending(path: "yarn.lock")
                if let before = try? String(contentsOf: file, encoding: .utf8) {
                    var after = before
                    var removed: [String] = []
                    for (name, version) in group.relock {
                        if let result = YarnLock.removing(name, version: version, from: after) {
                            after = result.text
                            removed += result.removed
                        } else {
                            dropped.insert("\(project.path)|\(name)")
                            skipped.append(String(localized: "\(name) (\(project.lastPathComponent)) : entrée introuvable dans yarn.lock"))
                        }
                    }
                    if after != before {
                        edits.append(.editFile(FileEdit(file: file, before: before, after: after, added: [], removed: removed)))
                        changed = true
                        notes.append(String(localized: "Sous-paquets : leurs entrées sont retirées du yarn.lock, puis « yarn install » les réinstalle dans la dernière version que permettent leurs parents (« yarn upgrade » ne le fait pas pour un sous-paquet)."))
                    }
                }
            }
            if changed, let install = DependencyOverride.install(for: group.manager, in: project) { installs.append(install) }
        }
        planned.removeAll { dropped.contains("\($0.project?.path ?? "")|\($0.dependency.name)") }
        guard !commands.isEmpty || !edits.isEmpty else { return nil }
        for package in planned {
            if let project = package.project {
                expected.append(DependencyExpectation(project: project, file: package.file,
                                                      name: package.dependency.name, vulnerableVersion: package.dependency.version))
            }
        }
        let first = packages[0]
        let major = packages.contains { p in p.fixedVersion.map { UpdateGap.between(p.dependency.version, $0) == .major } ?? false }
        let forcing = edits.contains { if case .editFile(let edit) = $0 { edit.file.lastPathComponent == "package.json" && !edit.added.isEmpty } else { false } }
        var plan = ActionPlan(
            title: packages.count == 1
                ? (forcing
                    ? String(localized: "Forcer \(first.dependency.name) en \(first.fixedVersion ?? "") (\(first.projectName))")
                    : String(localized: "Mettre à jour \(first.dependency.name) vers \(first.fixedVersion ?? "") (\(first.projectName))"))
                : String(localized: "Corriger \(packages.count) paquets vulnérables"),
            summary: (major ? String(localized: "Changement de version majeure : des incompatibilités sont possibles. ") : "")
                + notes.map { $0 + " " }.joined()
                + String(localized: "Modifie le manifeste et le lockfile du projet ; annulable avec git. Relancez les tests du projet ensuite."),
            kind: .paquet, risk: .caution, reversible: true,
            steps: edits + commands.map(ActionStep.command) + installs.map(ActionStep.command), skipped: skipped, stopOnFailure: false
        )
        plan.purpose = .dependencyFix(expected)
        return plan
    }

    /// « Aligner tous les projets sur X » : une commande par projet en retard.
    public static func alignPlan(_ library: Library) -> ActionPlan? {
        guard let latest = library.latest else { return nil }
        var skipped: [String] = []
        let commands = library.outdated.compactMap { use -> CommandSpec? in
            let command = upgradeDirect(library.name, to: latest, dev: use.dev, manager: use.manager, in: use.project)
            if command == nil { skipped.append(String(localized: "\(use.projectName) : \(use.manifest) à modifier à la main (\(use.manager.label))")) }
            return command
        }
        guard !commands.isEmpty else { return nil }
        let major = library.outdated.contains { $0.gap == .major }
        return ActionPlan(
            title: String(localized: "Aligner \(library.name) sur \(latest)"),
            summary: (major ? String(localized: "Mise à jour majeure : des changements incompatibles sont possibles. ") : "")
                + String(localized: "Modifie le manifeste et le lockfile de \(commands.count) projet(s) ; annulable avec git."),
            kind: .paquet, risk: major ? .caution : .safe, reversible: true,
            steps: commands.map(ActionStep.command), skipped: skipped, stopOnFailure: false
        )
    }
}

// MARK: - Analyse complète

public struct ProjectAnalyzer: Sendable {
    public let runner: CommandRunner
    public let projects: [URL]
    public let checkRemote: Bool
    /// Faux : pas de recherche de secrets (réglage « Détecter les secrets commités »).
    public var scanSecrets = true

    public init(runner: CommandRunner, projects: [URL], checkRemote: Bool = true, scanSecrets: Bool = true) {
        self.runner = runner
        self.projects = projects
        self.checkRemote = checkRemote
        self.scanSecrets = scanSecrets
    }

    public func analyze(force: Bool = false) async -> ProjectAnalysis {
        var analysis = ProjectAnalysis()
        analysis.projectCount = projects.count
        analysis.manifests = projects.flatMap(DependencyReader.read)

        let libraries = Set(analysis.manifests.flatMap(\.direct).map(\.libraryKey))
            .compactMap { key -> (Ecosystem, String)? in
                let parts = key.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let ecosystem = Ecosystem(rawValue: String(parts[0])) else { return nil }
                return (ecosystem, String(parts[1]))
            }
        let allDependencies = analysis.manifests.flatMap(\.dependencies)
        let runner = runner
        let projects = projects
        let checkRemote = checkRemote
        let scanSecrets = scanSecrets

        async let registry = checkRemote ? RegistryClient().latest(libraries.map { (ecosystem: $0.0, name: $0.1) }, force: force) : [:]
        async let osv: Result<[String: [Vulnerability]], Error> = {
            guard checkRemote else { return .success([:]) }
            do { return .success(try await OSVClient().vulnerabilities(of: allDependencies)) } catch { return .failure(error) }
        }()
        async let secrets = withTaskGroup(of: [SecretFinding].self) { group in
            for project in projects where scanSecrets { group.addTask { await SecretScanner.scan(repo: project, runner: runner) } }
            var all: [SecretFinding] = []
            for await found in group { all += found }
            return all.sorted { ($0.projectName, $0.file) < ($1.projectName, $1.file) }
        }
        async let nodeCycles = checkRemote ? EndOfLife.fetch("nodejs") : []
        async let pythonCycles = checkRemote ? EndOfLife.fetch("python") : []

        analysis.registry = await registry
        switch await osv {
        case .success(let found):
            for manifest in analysis.manifests {
                for dep in manifest.dependencies {
                    for vuln in found[dep.versionKey] ?? [] {
                        analysis.vulnerabilities.append(VulnerabilityFinding(
                            project: manifest.project, projectName: manifest.projectName,
                            file: manifest.lockfile ?? manifest.manifest, manager: manifest.manager,
                            dependency: dep, vulnerability: vuln, fixedVersion: vuln.fixedVersion(for: dep),
                            requiredBy: dep.direct ? [] : (manifest.requiredBy[dep.name] ?? []).filter { requirement in
                                // Seuls les parents qui ont choisi cette version-ci (sinon : autre exemplaire du paquet).
                                requirement.range.flatMap { SemverRange.satisfies(dep.version, $0) } ?? true
                            },
                            lockedVersions: manifest.dependencies.filter { $0.name == dep.name }.map(\.version)
                        ))
                    }
                }
            }
            analysis.vulnerabilities.sort { a, b in
                (a.severity, b.projectName, b.dependency.name) > (b.severity, a.projectName, a.dependency.name)
            }
        case .failure(let error):
            analysis.problems.append(error.localizedDescription)
        }
        let allSecrets = await secrets
        analysis.secrets = allSecrets.filter(\.sensitive)
        analysis.endOfLife = EndOfLifePins.find(projects: projects, node: await nodeCycles, python: await pythonCycles)

        var hygiene = Hygiene()
        hygiene.withoutRemote = projects.filter { project in
            // .git/config sans section [remote] ; un .git fichier (worktree, sous-module) est ignoré.
            guard let config = try? String(contentsOf: project.appending(path: ".git/config"), encoding: .utf8) else { return false }
            return !config.contains("[remote ")
        }
        .map(\.lastPathComponent).sorted()
        for manifest in analysis.manifests where manifest.lockfile == nil && !manifest.dependencies.isEmpty
            && ![.maven, .gradle, .pip].contains(manifest.manager) {
            hygiene.withoutLockfile.append((manifest.projectName, manifest.manifest))
        }
        for manifest in analysis.manifests where !manifest.extraLockfiles.isEmpty && manifest.lockfile != nil {
            hygiene.duplicateLockfiles.append((manifest.projectName, [manifest.lockfile!] + manifest.extraLockfiles))
        }
        hygiene.trackedEnvFiles = allSecrets.filter { !$0.sensitive }
        analysis.hygiene = hygiene
        analysis.checkedAt = .now
        return analysis
    }
}

/// Ce qui mérite une alerte : les projets **actifs** touchés par une faille **critique**.
/// (Compter chaque paquet vulnérable de chaque vieux projet donnait des pastilles à 900 et plus.)
public enum SecurityAlerts {
    public static func activeCriticalProjects(
        _ vulnerable: [VulnerablePackage], lastActivity: [URL: Date], inactiveAfter: TimeInterval, now: Date = .now
    ) -> [URL] {
        let projects = Set(vulnerable.filter { $0.severity == .critical }.compactMap { $0.project?.standardizedFileURL })
        return projects.filter { project in
            // Projet inconnu de la liste des dépôts : on le garde (mieux vaut une alerte de trop).
            guard let date = lastActivity[project] else { return true }
            return now.timeIntervalSince(date) <= inactiveAfter
        }
        .sorted { $0.path < $1.path }
    }
}
