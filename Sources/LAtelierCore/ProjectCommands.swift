import Foundation

/// Usage d'une commande de projet, pour la classer.
public enum CommandCategory: Int, Sendable, CaseIterable, Codable, Comparable {
    case run, test, build, quality, deploy, other

    public var title: String {
        switch self {
        case .run: "Lancer"
        case .test: "Tester"
        case .build: "Construire"
        case .quality: "Qualité"
        case .deploy: "Déployer"
        case .other: "Autres"
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// D'après le nom (et la commande) : `dev` → Lancer, `test:e2e` → Tester…
    static func guess(name: String, body: String = "") -> CommandCategory {
        let n = name.lowercased()
        let words = n.split(whereSeparator: { ":-_. ".contains($0) }).map(String.init)
        func has(_ keys: [String]) -> Bool { words.contains { w in keys.contains { w == $0 || w.hasPrefix($0) } } }
        if has(["deploy", "release", "publish", "ship"]) { return .deploy }
        if has(["test", "spec", "e2e", "coverage", "cov", "jest", "vitest", "pytest", "bench"]) { return .test }
        if has(["lint", "format", "fmt", "prettier", "eslint", "typecheck", "tsc", "check", "clippy", "audit", "biome", "vet", "ruff", "mypy"]) { return .quality }
        if has(["build", "compile", "package", "bundle", "dist", "pack", "assemble", "export", "generate", "gen"]) { return .build }
        if has(["dev", "start", "serve", "server", "run", "up", "watch", "preview", "storybook", "worker", "boot"]) { return .run }
        let b = body.lowercased()
        if b.contains("jest") || b.contains("vitest") || b.contains("pytest") || b.contains("playwright test") { return .test }
        if b.contains("eslint") || b.contains("prettier") || b.contains("tsc --noemit") { return .quality }
        return .other
    }
}

/// Une commande détectée dans un projet (script npm, cible make, recette just…).
public struct ProjectCommand: Sendable, Identifiable, Hashable, Codable {
    public var name: String
    public var spec: CommandSpec
    /// D'où elle vient : `package.json`, `Makefile`, `compose`…
    public var source: String
    public var category: CommandCategory
    /// Contenu du script (pour package.json), affiché en aide.
    public var body: String?

    public var id: String { "\(source):\(name)" }

    /// Déploiement, migrations, suppressions : confirmation demandée (aperçu) avant exécution.
    public var isSensitive: Bool {
        if category == .deploy { return true }
        let text = (name + " " + (body ?? "") + " " + spec.arguments.joined(separator: " ")).lowercased()
        return ["deploy", "release", "publish", "migrat", "drop ", "destroy", "rm -rf", "prune", "reset", "seed", "prod", "terraform apply", "kubectl delete"]
            .contains { text.contains($0) }
    }

    /// Ce qu'on tape dans un terminal (sans le `cd`).
    public var commandLine: String {
        ([spec.tool] + spec.arguments).map(ShellQuote.quote).joined(separator: " ")
    }
}

/// Une amélioration proposée pour les commandes du projet.
public struct CommandSuggestion: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable { case addLint, addCoverage, addTest, portBusy, addTypecheck }

    public var kind: Kind
    public var title: String
    public var why: String
    /// Ce qui sera ajouté (ligne de package.json) ou la commande à lancer.
    public var preview: String
    /// Modification du fichier, si la suggestion en est une.
    public var edit: FileEdit?

    public var id: String { kind.rawValue }
}

/// Modification d'un fichier texte : remplacer tout le contenu, en vérifiant qu'il n'a pas changé depuis.
public struct FileEdit: Sendable, Hashable {
    public var file: URL
    public var before: String
    public var after: String
    /// Lignes ajoutées et retirées, pour l'aperçu.
    public var added: [String]
    public var removed: [String]
    /// Met l'ancienne version à la corbeille avant d'écrire (~/.ssh/config).
    public var backup: Bool

    public init(file: URL, before: String, after: String, added: [String], removed: [String] = [], backup: Bool = false) {
        self.file = file
        self.before = before
        self.after = after
        self.added = added
        self.removed = removed
        self.backup = backup
    }
}

public struct ProjectCommandSet: Sendable {
    public var project: URL
    public var commands: [ProjectCommand]
    public var suggestions: [CommandSuggestion]
    /// Fichiers lus (« package.json, docker-compose.yml »).
    public var sources: [String]
}

public enum ProjectCommandDetector {
    /// Lit les fichiers du projet et rend ses commandes. Pas de commande lancée.
    public static func detect(_ project: URL, locator: ToolLocator = .standard) -> ProjectCommandSet {
        let fm = FileManager.default
        func file(_ name: String) -> URL? {
            let url = project.appendingPathComponent(name)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        func text(_ name: String) -> String? { file(name).flatMap { try? String(contentsOf: $0, encoding: .utf8) } }

        var commands: [ProjectCommand] = []
        var sources: [String] = []
        var suggestions: [CommandSuggestion] = []

        if let json = text("package.json") {
            let manager = jsManager(project)
            let scripts = packageScripts(json)
            sources.append("package.json")
            for (name, body) in scripts {
                commands.append(ProjectCommand(
                    name: name, spec: manager.runSpec(name, in: project), source: "package.json",
                    category: CommandCategory.guess(name: name, body: body), body: body
                ))
            }
            if let url = file("package.json") {
                suggestions += jsSuggestions(json: json, scripts: scripts, file: url)
            }
        }
        for name in ["Makefile", "makefile", "GNUmakefile"] {
            if let make = text(name) {
                sources.append(name)
                for target in makeTargets(make) {
                    commands.append(ProjectCommand(name: target, spec: CommandSpec("make", [target], in: project), source: "Makefile",
                                                   category: CommandCategory.guess(name: target)))
                }
                break
            }
        }
        for name in ["justfile", "Justfile", ".justfile"] {
            if let just = text(name) {
                sources.append("justfile")
                for recipe in justRecipes(just) {
                    commands.append(ProjectCommand(name: recipe, spec: CommandSpec("just", [recipe], in: project), source: "justfile",
                                                   category: CommandCategory.guess(name: recipe)))
                }
                break
            }
        }
        for name in ["Taskfile.yml", "Taskfile.yaml", "taskfile.yml"] {
            if let task = text(name) {
                sources.append("Taskfile")
                for t in taskfileTasks(task) {
                    commands.append(ProjectCommand(name: t, spec: CommandSpec("task", [t], in: project), source: "Taskfile",
                                                   category: CommandCategory.guess(name: t)))
                }
                break
            }
        }
        for name in ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"] {
            if let compose = text(name) {
                sources.append(name)
                commands.append(ProjectCommand(name: "up", spec: CommandSpec("docker", ["compose", "up"], in: project), source: "compose", category: .run))
                for service in composeServices(compose) {
                    commands.append(ProjectCommand(name: service, spec: CommandSpec("docker", ["compose", "up", "-d", service], in: project),
                                                   source: "compose", category: .run))
                }
                commands.append(ProjectCommand(name: "down", spec: CommandSpec("docker", ["compose", "down"], in: project), source: "compose", category: .other))
                break
            }
        }
        if let cargo = text("Cargo.toml") {
            sources.append("Cargo.toml")
            let isBinary = cargo.contains("[[bin]]") || fm.fileExists(atPath: project.appendingPathComponent("src/main.rs").path)
            if isBinary { commands.append(cargoCommand("run", project, .run)) }
            commands.append(cargoCommand("test", project, .test))
            commands.append(cargoCommand("build", project, .build, extra: ["--release"]))
            commands.append(cargoCommand("clippy", project, .quality))
        }
        if text("go.mod") != nil {
            sources.append("go.mod")
            if fm.fileExists(atPath: project.appendingPathComponent("main.go").path) {
                commands.append(ProjectCommand(name: "run", spec: CommandSpec("go", ["run", "."], in: project), source: "Go", category: .run))
            }
            commands.append(ProjectCommand(name: "test", spec: CommandSpec("go", ["test", "./..."], in: project), source: "Go", category: .test))
            commands.append(ProjectCommand(name: "build", spec: CommandSpec("go", ["build", "./..."], in: project), source: "Go", category: .build))
            commands.append(ProjectCommand(name: "vet", spec: CommandSpec("go", ["vet", "./..."], in: project), source: "Go", category: .quality))
        }
        if let pom = text("pom.xml") {
            sources.append("pom.xml")
            let tool = file("mvnw") != nil ? "./mvnw" : "mvn"
            func maven(_ name: String, _ args: [String], _ category: CommandCategory) -> ProjectCommand {
                ProjectCommand(name: name, spec: CommandSpec(tool, args, in: project), source: "Maven", category: category)
            }
            if pom.contains("spring-boot-maven-plugin") { commands.append(maven("spring-boot:run", ["spring-boot:run"], .run)) }
            commands.append(maven("test", ["test"], .test))
            commands.append(maven("package", ["package", "-DskipTests"], .build))
            commands.append(maven("verify", ["verify"], .quality))
        }
        if let gradle = text("build.gradle.kts") ?? text("build.gradle") {
            sources.append("Gradle")
            let tool = file("gradlew") != nil ? "./gradlew" : "gradle"
            func task(_ name: String, _ category: CommandCategory) -> ProjectCommand {
                ProjectCommand(name: name, spec: CommandSpec(tool, [name], in: project), source: "Gradle", category: category)
            }
            if gradle.contains("org.springframework.boot") { commands.append(task("bootRun", .run)) }
            if gradle.contains("application") { commands.append(task("run", .run)) }
            commands.append(task("test", .test))
            commands.append(task("build", .build))
        }
        if let pyproject = text("pyproject.toml") {
            sources.append("pyproject.toml")
            let runner: [String] = file("uv.lock") != nil ? ["uv", "run"] : file("poetry.lock") != nil ? ["poetry", "run"] : []
            for (name, _) in pythonScripts(pyproject) {
                let spec = runner.isEmpty ? CommandSpec(name, [], in: project) : CommandSpec(runner[0], Array(runner.dropFirst()) + [name], in: project)
                commands.append(ProjectCommand(name: name, spec: spec, source: "pyproject", category: CommandCategory.guess(name: name)))
            }
            if pyproject.contains("pytest") {
                let spec = runner.isEmpty ? CommandSpec("pytest", [], in: project) : CommandSpec(runner[0], Array(runner.dropFirst()) + ["pytest"], in: project)
                commands.append(ProjectCommand(name: "pytest", spec: spec, source: "pyproject", category: .test))
            }
            if pyproject.contains("ruff") {
                let spec = runner.isEmpty ? CommandSpec("ruff", ["check", "."], in: project) : CommandSpec(runner[0], Array(runner.dropFirst()) + ["ruff", "check", "."], in: project)
                commands.append(ProjectCommand(name: "ruff", spec: spec, source: "pyproject", category: .quality))
            }
        }
        if text("Package.swift") != nil {
            sources.append("Package.swift")
            commands.append(ProjectCommand(name: "build", spec: CommandSpec("swift", ["build"], in: project), source: "Swift", category: .build))
            commands.append(ProjectCommand(name: "test", spec: CommandSpec("swift", ["test"], in: project), source: "Swift", category: .test))
            commands.append(ProjectCommand(name: "run", spec: CommandSpec("swift", ["run"], in: project), source: "Swift", category: .run))
        }

        // Une même commande peut venir de deux sources (make test + npm test) : on garde les deux, ids distincts.
        var seen = Set<String>()
        commands = commands.filter { seen.insert($0.id).inserted }
        return ProjectCommandSet(project: project, commands: commands, suggestions: suggestions, sources: sources)
    }

    static func cargoCommand(_ name: String, _ project: URL, _ category: CommandCategory, extra: [String] = []) -> ProjectCommand {
        ProjectCommand(name: name, spec: CommandSpec("cargo", [name] + extra, in: project), source: "Cargo", category: category)
    }

    // MARK: JavaScript

    public enum JSManager: String, Sendable {
        case npm, yarn, pnpm, bun

        func runSpec(_ script: String, in project: URL) -> CommandSpec {
            switch self {
            case .npm: CommandSpec("npm", ["run", script], in: project)
            case .yarn: CommandSpec("yarn", [script], in: project)
            case .pnpm: CommandSpec("pnpm", ["run", script], in: project)
            case .bun: CommandSpec("bun", ["run", script], in: project)
            }
        }
    }

    static func jsManager(_ project: URL) -> JSManager {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: project.appendingPathComponent(name).path) }
        if let json = try? String(contentsOf: project.appendingPathComponent("package.json"), encoding: .utf8),
           let range = json.range(of: #""packageManager"\s*:\s*"([a-z]+)@"#, options: .regularExpression) {
            let value = json[range]
            for manager in [JSManager.pnpm, .yarn, .bun, .npm] where value.contains("\"\(manager.rawValue)@") { return manager }
        }
        if has("pnpm-lock.yaml") { return .pnpm }
        if has("yarn.lock") { return .yarn }
        if has("bun.lockb") || has("bun.lock") { return .bun }
        return .npm
    }

    /// Scripts dans l'ordre du fichier.
    static func packageScripts(_ json: String) -> [(String, String)] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = object["scripts"] as? [String: String] else { return [] }
        // JSONSerialization perd l'ordre : on le retrouve dans le texte.
        return scripts.sorted { a, b in
            (json.range(of: "\"\(a.key)\"")?.lowerBound ?? json.endIndex) < (json.range(of: "\"\(b.key)\"")?.lowerBound ?? json.endIndex)
        }.map { ($0.key, $0.value) }
    }

    static func jsSuggestions(json: String, scripts: [(String, String)], file: URL) -> [CommandSuggestion] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var deps: Set<String> = []
        for key in ["dependencies", "devDependencies"] {
            (object[key] as? [String: Any])?.keys.forEach { deps.insert($0) }
        }
        let names = Set(scripts.map(\.0))
        let bodies = scripts.map(\.1).joined(separator: " ")
        var result: [CommandSuggestion] = []

        if !names.contains(where: { $0 == "lint" || $0.hasPrefix("lint:") }) {
            var line: (String, String)?
            if deps.contains("eslint") { line = ("lint", "eslint .") }
            else if deps.contains("@biomejs/biome") { line = ("lint", "biome check .") }
            if let line, let edit = addScript(line.0, line.1, to: json, file: file) {
                result.append(CommandSuggestion(
                    kind: .addLint, title: "Ajouter une commande « lint »",
                    why: "\(line.1.split(separator: " ").first!) est dans les dépendances mais aucun script « lint » n’existe.",
                    preview: "\"\(line.0)\": \"\(line.1)\"", edit: edit
                ))
            }
        }
        if !names.contains(where: { $0.contains("coverage") || $0.contains("cov") }) && !bodies.contains("--coverage") {
            var line: (String, String)?
            if deps.contains("vitest") { line = ("test:coverage", "vitest run --coverage") }
            else if deps.contains("jest") { line = ("test:coverage", "jest --coverage") }
            if let line, let edit = addScript(line.0, line.1, to: json, file: file) {
                result.append(CommandSuggestion(
                    kind: .addCoverage, title: "Ajouter « test:coverage »",
                    why: "Pour mesurer la couverture des tests (Projets › Couverture).",
                    preview: "\"\(line.0)\": \"\(line.1)\"", edit: edit
                ))
            }
        }
        if !names.contains("typecheck"), deps.contains("typescript"), !bodies.contains("tsc") {
            if let edit = addScript("typecheck", "tsc --noEmit", to: json, file: file) {
                result.append(CommandSuggestion(
                    kind: .addTypecheck, title: "Ajouter « typecheck »",
                    why: "TypeScript est installé mais rien ne vérifie les types sans construire.",
                    preview: "\"typecheck\": \"tsc --noEmit\"", edit: edit
                ))
            }
        }
        return result
    }

    /// Ajoute une ligne à la fin du bloc `"scripts"` en gardant le reste du fichier intact.
    static func addScript(_ name: String, _ body: String, to json: String, file: URL) -> FileEdit? {
        guard let start = json.range(of: #""scripts"\s*:\s*\{"#, options: .regularExpression) else { return nil }
        // Fin du bloc : accolade fermante au même niveau.
        var depth = 1
        var index = start.upperBound
        var inString = false
        var escaped = false
        while index < json.endIndex, depth > 0 {
            let c = json[index]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { break } }
            index = json.index(after: index)
        }
        guard depth == 0 else { return nil }
        let inner = json[start.upperBound..<index]
        // Indentation des lignes existantes.
        let existingLine = inner.split(separator: "\n").first { $0.contains("\"") }
        let indent = existingLine.map { String($0.prefix { $0 == " " || $0 == "\t" }) } ?? "    "
        let escapedBody = body.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let newLine = "\(indent)\"\(name)\": \"\(escapedBody)\""
        let trimmedInner = inner.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        let closingIndent = String(inner.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
        let rebuilt: String
        if trimmedInner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rebuilt = "\n" + newLine + "\n" + closingIndent
        } else {
            rebuilt = trimmedInner + ",\n" + newLine + "\n" + closingIndent
        }
        let after = String(json[..<start.upperBound]) + rebuilt + String(json[index...])
        return FileEdit(file: file, before: json, after: after, added: [newLine.trimmingCharacters(in: .whitespaces)])
    }

    // MARK: Autres sources

    static func makeTargets(_ text: String) -> [String] {
        var targets: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let first = line.first, first != "\t", first != " ", first != "#", first != "." else { continue }
            guard let colon = line.firstIndex(of: ":"), line[line.index(after: colon)...].first != "=" else { continue }
            let head = line[..<colon]
            if head.contains("=") || head.contains("%") || head.contains("$") || head.contains("/") { continue }
            for name in head.split(separator: " ") where !name.isEmpty {
                let target = String(name)
                if !targets.contains(target) { targets.append(target) }
            }
        }
        return targets
    }

    static func justRecipes(_ text: String) -> [String] {
        var recipes: [String] = []
        for line in text.split(separator: "\n") {
            guard let first = line.first, first.isLetter || first == "_" || first == "@" else { continue }
            if line.hasPrefix("set ") || line.hasPrefix("alias ") || line.hasPrefix("export ") || line.hasPrefix("import ") || line.hasPrefix("mod ") { continue }
            guard let colon = line.firstIndex(of: ":"), line[line.index(after: colon)...].first != "=" else { continue }
            var name = line[..<colon].split(separator: " ").first.map(String.init) ?? ""
            if name.hasPrefix("@") { name.removeFirst() }
            if name.hasPrefix("_") || name.contains(":=") || name.isEmpty { continue }
            if !recipes.contains(name) { recipes.append(name) }
        }
        return recipes
    }

    /// Clés directement sous `tasks:` (indentation de la première tâche).
    static func taskfileTasks(_ text: String) -> [String] {
        var tasks: [String] = []
        var inTasks = false
        var indent: Int?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("tasks:") { inTasks = true; continue }
            guard inTasks else { continue }
            let spaces = line.prefix { $0 == " " }.count
            if spaces == 0, !line.hasPrefix("#") { break }
            let trimmed = line.dropFirst(spaces)
            guard !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") else { continue }
            if indent == nil { indent = spaces }
            if spaces == indent {
                let name = String(trimmed[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if !name.isEmpty { tasks.append(name) }
            }
        }
        return tasks
    }

    static func composeServices(_ text: String) -> [String] {
        var services: [String] = []
        var inServices = false
        var indent: Int?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("services:") { inServices = true; continue }
            guard inServices else { continue }
            let spaces = line.prefix { $0 == " " }.count
            if spaces == 0, !line.hasPrefix("#") { break }
            let trimmed = line.dropFirst(spaces)
            guard !trimmed.hasPrefix("#"), trimmed.hasSuffix(":") else { continue }
            if indent == nil { indent = spaces }
            if spaces == indent { services.append(String(trimmed.dropLast())) }
        }
        return services
    }

    /// `[project.scripts]`, `[tool.poetry.scripts]`, `[tool.pdm.scripts]`.
    static func pythonScripts(_ text: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var inScripts = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inScripts = ["[project.scripts]", "[tool.poetry.scripts]", "[tool.pdm.scripts]"].contains(line)
                continue
            }
            guard inScripts, let eq = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
            let name = line[..<eq].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            let value = line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !name.isEmpty { result.append((name, value)) }
        }
        return result
    }
}

// MARK: - Suivi des exécutions

/// Dernier résultat et épingles, gardés localement.
public struct CommandRunRecord: Sendable, Codable, Hashable {
    public var date: Date
    public var status: Int32?
    public var duration: TimeInterval
    /// Fin de la sortie en cas d'échec (pour « Demander à Claude » et les suggestions).
    public var errorTail: [String]

    public var succeeded: Bool { status == 0 }

    public init(date: Date, status: Int32?, duration: TimeInterval, errorTail: [String]) {
        self.date = date
        self.status = status
        self.duration = duration
        self.errorTail = errorTail
    }
}

public struct CommandState: Sendable, Codable {
    public var runs: [String: CommandRunRecord] = [:]
    public var pins: Set<String> = []
    public var dismissed: Set<String> = []
    /// Nombre d'échecs « port occupé » par commande.
    public var portFailures: [String: Int] = [:]

    public init() {}

    public static func key(_ project: URL, _ command: ProjectCommand) -> String { "\(project.path)#\(command.id)" }
    public static func key(_ project: URL, _ suggestion: String) -> String { "\(project.path)#suggest:\(suggestion)" }

    /// Détecte « port occupé » dans une sortie d'erreur.
    public static func busyPort(in lines: [String]) -> Int? {
        let text = lines.joined(separator: "\n")
        guard text.contains("EADDRINUSE") || text.localizedCaseInsensitiveContains("address already in use")
            || text.localizedCaseInsensitiveContains("port is already in use") || text.contains("is already in use") else { return nil }
        guard let range = text.range(of: #":(\d{2,5})\b"#, options: .regularExpression) ?? text.range(of: #"port (\d{2,5})"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let digits = text[range].filter(\.isNumber)
        return Int(digits)
    }
}

/// Fichier JSON dans Application Support, écrit atomiquement.
public actor JSONStore<Value: Codable & Sendable> {
    public let url: URL
    private let fallback: Value

    public init(name: String, fallback: Value, directory: URL? = nil) {
        let base = directory ?? AppPaths.supportDirectory
        url = base.appendingPathComponent(name)
        self.fallback = fallback
    }

    public func load() -> Value {
        guard let data = try? Data(contentsOf: url) else { return fallback }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Value.self, from: data)) ?? fallback
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
