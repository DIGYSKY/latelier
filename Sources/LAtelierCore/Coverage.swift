import Foundation

/// Couverture d'un fichier.
public struct FileCoverage: Sendable, Hashable, Codable {
    public var path: String
    public var linesCovered: Int
    public var linesTotal: Int

    public var percent: Double { linesTotal == 0 ? 100 : Double(linesCovered) / Double(linesTotal) * 100 }
}

/// Résultat d'un rapport de couverture.
public struct CoverageReport: Sendable, Hashable, Codable {
    public enum Format: String, Sendable, Codable {
        case lcov, cobertura, jacoco, llvmJSON, goProfile

        public var label: String {
            switch self {
            case .lcov: "lcov"
            case .cobertura: "Cobertura"
            case .jacoco: "JaCoCo"
            case .llvmJSON: "llvm-cov"
            case .goProfile: "go cover"
            }
        }
    }

    public var format: Format
    public var file: String
    public var date: Date
    public var lines: Double
    public var branches: Double?
    public var functions: Double?
    public var files: [FileCoverage]

    /// Fichiers les moins couverts (au moins 5 lignes).
    public func weakest(_ count: Int = 6) -> [FileCoverage] {
        Array(files.filter { $0.linesTotal >= 5 }.sorted { ($0.percent, -$0.linesTotal) < ($1.percent, -$1.linesTotal) }.prefix(count))
    }
}

public enum CoverageParser {
    // MARK: lcov

    public static func lcov(_ text: String, root: URL? = nil) -> (lines: Double, branches: Double?, functions: Double?, files: [FileCoverage])? {
        var files: [FileCoverage] = []
        var current: String?
        var lf = 0, lh = 0, brf = 0, brh = 0, fnf = 0, fnh = 0
        var fileLF = 0, fileLH = 0
        var daTotal = 0, daHit = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("SF:") {
                current = String(line.dropFirst(3)); fileLF = 0; fileLH = 0; daTotal = 0; daHit = 0
            } else if line.hasPrefix("DA:") {
                daTotal += 1
                let parts = line.dropFirst(3).split(separator: ",")
                if parts.count >= 2, (Int(parts[1]) ?? 0) > 0 { daHit += 1 }
            } else if line.hasPrefix("LF:") { fileLF = Int(line.dropFirst(3)) ?? 0 }
            else if line.hasPrefix("LH:") { fileLH = Int(line.dropFirst(3)) ?? 0 }
            else if line.hasPrefix("BRF:") { brf += Int(line.dropFirst(4)) ?? 0 }
            else if line.hasPrefix("BRH:") { brh += Int(line.dropFirst(4)) ?? 0 }
            else if line.hasPrefix("FNF:") { fnf += Int(line.dropFirst(4)) ?? 0 }
            else if line.hasPrefix("FNH:") { fnh += Int(line.dropFirst(4)) ?? 0 }
            else if line == "end_of_record", let path = current {
                let total = fileLF > 0 ? fileLF : daTotal
                let hit = fileLF > 0 ? fileLH : daHit
                lf += total
                lh += hit
                files.append(FileCoverage(path: relative(path, root), linesCovered: hit, linesTotal: total))
                current = nil
            }
        }
        guard lf > 0 else { return nil }
        return (percent(lh, lf), brf > 0 ? percent(brh, brf) : nil, fnf > 0 ? percent(fnh, fnf) : nil, files)
    }

    // MARK: Cobertura (pytest-cov, coverage.py, istanbul cobertura)

    public static func cobertura(_ text: String, root: URL? = nil) -> (lines: Double, branches: Double?, functions: Double?, files: [FileCoverage])? {
        guard let coverage = firstTag("coverage", in: text) else { return nil }
        let lineRate = attribute("line-rate", in: coverage).flatMap(Double.init)
        let branchRate = attribute("branch-rate", in: coverage).flatMap(Double.init)
        let branchesValid = attribute("branches-valid", in: coverage).flatMap(Int.init) ?? 1
        var files: [FileCoverage] = []
        var cursor = text.startIndex
        while let start = text.range(of: "<class ", range: cursor..<text.endIndex) {
            let end = text.range(of: "</class>", range: start.upperBound..<text.endIndex)?.upperBound
                ?? text.range(of: "/>", range: start.upperBound..<text.endIndex)?.upperBound ?? text.endIndex
            let block = String(text[start.lowerBound..<end])
            if let name = attribute("filename", in: block) {
                let hits = block.components(separatedBy: "<line ").dropFirst().map { attribute("hits", in: $0).flatMap(Int.init) ?? 0 }
                if let i = files.firstIndex(where: { $0.path == name }) {
                    files[i].linesTotal += hits.count
                    files[i].linesCovered += hits.filter { $0 > 0 }.count
                } else {
                    files.append(FileCoverage(path: relative(name, root), linesCovered: hits.filter { $0 > 0 }.count, linesTotal: hits.count))
                }
            }
            cursor = end
        }
        guard let lineRate else { return nil }
        return (lineRate * 100, branchRate.flatMap { branchesValid > 0 ? $0 * 100 : nil }, nil, files)
    }

    // MARK: JaCoCo

    public static func jacoco(_ text: String) -> (lines: Double, branches: Double?, functions: Double?, files: [FileCoverage])? {
        // Les compteurs du rapport sont les derniers, directement sous <report>.
        func counters(_ block: Substring) -> [String: (missed: Int, covered: Int)] {
            var result: [String: (Int, Int)] = [:]
            for part in block.components(separatedBy: "<counter ").dropFirst() {
                guard let type = attribute("type", in: part), let missed = attribute("missed", in: part).flatMap(Int.init),
                      let covered = attribute("covered", in: part).flatMap(Int.init) else { continue }
                result[type] = (missed, covered)
            }
            return result
        }
        guard let reportEnd = text.range(of: "</report>", options: .backwards) else { return nil }
        let lastPackageEnd = text.range(of: "</package>", options: .backwards)?.upperBound ?? text.startIndex
        let totals = counters(text[lastPackageEnd..<reportEnd.lowerBound])
        guard let line = totals["LINE"], line.missed + line.covered > 0 else { return nil }
        func pct(_ c: (missed: Int, covered: Int)?) -> Double? {
            guard let c, c.missed + c.covered > 0 else { return nil }
            return percent(c.covered, c.missed + c.covered)
        }
        var files: [FileCoverage] = []
        var packageName = ""
        var cursor = text.startIndex
        while let start = text.range(of: "<sourcefile ", range: cursor..<text.endIndex) {
            if let pkg = text.range(of: "<package ", options: .backwards, range: text.startIndex..<start.lowerBound),
               let name = attribute("name", in: String(text[pkg.lowerBound..<start.lowerBound].prefix(400))) {
                packageName = name
            }
            guard let end = text.range(of: "</sourcefile>", range: start.upperBound..<text.endIndex) else { break }
            let block = text[start.lowerBound..<end.upperBound]
            if let name = attribute("name", in: String(block.prefix(300))), let c = counters(block)["LINE"] {
                files.append(FileCoverage(path: packageName.isEmpty ? name : "\(packageName)/\(name)", linesCovered: c.covered, linesTotal: c.missed + c.covered))
            }
            cursor = end.upperBound
        }
        return (pct(line)!, pct(totals["BRANCH"]), pct(totals["METHOD"]), files)
    }

    // MARK: llvm-cov export (swift test --enable-code-coverage, cargo llvm-cov --json)

    public static func llvmJSON(_ data: Data, root: URL? = nil) -> (lines: Double, branches: Double?, functions: Double?, files: [FileCoverage])? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (object["data"] as? [[String: Any]])?.first else { return nil }
        let rootPath = root?.path
        var files: [FileCoverage] = []
        var covered = 0, total = 0
        for file in first["files"] as? [[String: Any]] ?? [] {
            guard let name = file["filename"] as? String, let lines = (file["summary"] as? [String: Any])?["lines"] as? [String: Any] else { continue }
            // Swift : on ne garde que les sources du projet (pas .build/checkouts ni les tests).
            if let rootPath, !name.hasPrefix(rootPath) { continue }
            if name.contains("/.build/") || name.contains("/Tests/") || name.contains("/tests/") { continue }
            let c = lines["covered"] as? Int ?? 0
            let t = lines["count"] as? Int ?? 0
            covered += c
            total += t
            files.append(FileCoverage(path: relative(name, root), linesCovered: c, linesTotal: t))
        }
        guard total > 0 else { return nil }
        let totals = first["totals"] as? [String: Any]
        func pct(_ key: String) -> Double? {
            guard let entry = totals?[key] as? [String: Any], (entry["count"] as? Int ?? 0) > 0 else { return nil }
            return entry["percent"] as? Double
        }
        // Totaux recalculés sur les seuls fichiers du projet.
        return (percent(covered, total), pct("branches"), pct("functions"), files)
    }

    // MARK: Go (`go test -coverprofile`)

    public static func goProfile(_ text: String, module: String? = nil) -> (lines: Double, branches: Double?, functions: Double?, files: [FileCoverage])? {
        var byFile: [String: (covered: Int, total: Int)] = [:]
        var seen = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) where !raw.hasPrefix("mode:") {
            // fichier.go:12.34,15.2 3 1  (blocs, nombre d'instructions, compteur)
            let parts = raw.split(separator: " ")
            guard parts.count == 3, let statements = Int(parts[1]), let count = Int(parts[2]),
                  let colon = parts[0].lastIndex(of: ":") else { continue }
            let file = String(parts[0][..<colon])
            let block = String(parts[0])
            // Avec plusieurs paquets, un bloc peut apparaître deux fois : on garde le meilleur.
            if seen.contains(block) { continue }
            seen.insert(block)
            byFile[file, default: (0, 0)].total += statements
            if count > 0 { byFile[file, default: (0, 0)].covered += statements }
        }
        let total = byFile.values.reduce(0) { $0 + $1.total }
        guard total > 0 else { return nil }
        let covered = byFile.values.reduce(0) { $0 + $1.covered }
        let files = byFile.map { path, v in
            FileCoverage(path: module.map { path.hasPrefix($0 + "/") ? String(path.dropFirst($0.count + 1)) : path } ?? path,
                         linesCovered: v.covered, linesTotal: v.total)
        }
        return (percent(covered, total), nil, nil, files)
    }

    // MARK: Outils

    static func percent(_ part: Int, _ total: Int) -> Double { total == 0 ? 0 : Double(part) / Double(total) * 100 }

    static func relative(_ path: String, _ root: URL?) -> String {
        guard let root, path.hasPrefix(root.path + "/") else { return path }
        return String(path.dropFirst(root.path.count + 1))
    }

    static func firstTag(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(name) "), let end = text.range(of: ">", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.lowerBound..<end.upperBound])
    }

    static func attribute(_ name: String, in text: String) -> String? {
        guard let range = text.range(of: " \(name)=\"") ?? text.range(of: "\(name)=\"") else { return nil }
        guard let end = text[range.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(text[range.upperBound..<end])
    }
}

// MARK: - Détection par projet

/// Comment mesurer la couverture d'un projet, et où trouver le rapport.
public struct CoverageSetup: Sendable, Hashable {
    /// Outil de couverture absent du projet, et comment l'ajouter.
    public struct Missing: Sendable, Hashable {
        /// « @vitest/coverage-v8 »
        public var package: String
        public var install: CommandSpec
        /// Vrai si la commande installe un outil global (cargo install) plutôt qu'une dépendance du projet.
        public var global: Bool = false
        public var why: String
    }

    public var tool: String
    public var command: CommandSpec?
    /// Chemins (relatifs au projet) où chercher un rapport, par ordre de préférence.
    public var reports: [String]
    public var missing: Missing?

    public init(tool: String, command: CommandSpec?, reports: [String], missing: Missing? = nil) {
        self.tool = tool
        self.command = command
        self.reports = reports
        self.missing = missing
    }
}

public enum CoverageDetector {
    static let knownReports = [
        "coverage/lcov.info", "lcov.info", "coverage/lcov/lcov.info", "target/llvm-cov/lcov.info", "target/lcov.info",
        "coverage.xml", "coverage/cobertura-coverage.xml", "coverage/coverage.xml",
        "target/site/jacoco/jacoco.xml", "build/reports/jacoco/test/jacocoTestReport.xml",
        "coverage.out", "cover.out",
    ]

    public static func setup(for project: URL) -> CoverageSetup? {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: project.appendingPathComponent(name).path) }
        func text(_ name: String) -> String { (try? String(contentsOf: project.appendingPathComponent(name), encoding: .utf8)) ?? "" }

        if has("package.json") {
            let json = text("package.json")
            let manager = ProjectCommandDetector.jsManager(project)
            let exec: (String, [String]) = switch manager {
            case .npm: ("npx", [])
            case .yarn: ("yarn", [])
            case .pnpm: ("pnpm", ["exec"])
            case .bun: ("bunx", [])
            }
            let add: [String] = switch manager {
            case .npm: ["npm", "install", "--save-dev"]
            case .yarn: ["yarn", "add", "--dev"]
            case .pnpm: ["pnpm", "add", "--save-dev"]
            case .bun: ["bun", "add", "--dev"]
            }
            let run = CommandSpec(exec.0, exec.1 + ["vitest", "run", "--coverage", "--coverage.reporter=lcov", "--coverage.reporter=text-summary"], in: project)
            if json.contains("\"vitest\"") {
                var missing: CoverageSetup.Missing?
                // Vitest a besoin d'un fournisseur de couverture, à la même version que lui.
                let providers = ["@vitest/coverage-v8", "@vitest/coverage-istanbul"]
                let installed = providers.contains { json.contains("\"\($0)\"") || has("node_modules/\($0)/package.json") }
                if !installed {
                    let version = requirement(of: "vitest", in: json).map { "@\($0)" } ?? ""
                    missing = CoverageSetup.Missing(
                        package: "@vitest/coverage-v8",
                        install: CommandSpec(add[0], Array(add.dropFirst()) + ["@vitest/coverage-v8\(version)"], in: project),
                        why: "Vitest est installé mais pas son module de couverture : sans lui, « vitest --coverage » échoue (MISSING DEPENDENCY)."
                    )
                }
                return CoverageSetup(tool: "Vitest", command: run, reports: ["coverage/lcov.info"] + knownReports, missing: missing)
            }
            if json.contains("\"jest\"") {
                return CoverageSetup(tool: "Jest", command: CommandSpec(exec.0, exec.1 + ["jest", "--coverage"], in: project),
                                     reports: ["coverage/lcov.info"] + knownReports)
            }
            // Projet JS sans outil de test : on propose Vitest et sa couverture.
            if json.contains("\"scripts\"") || has("src") {
                return CoverageSetup(tool: "Vitest", command: run, reports: ["coverage/lcov.info"] + knownReports, missing: CoverageSetup.Missing(
                    package: "vitest + @vitest/coverage-v8",
                    install: CommandSpec(add[0], Array(add.dropFirst()) + ["vitest", "@vitest/coverage-v8"], in: project),
                    why: "Aucun outil de test dans ce projet : Vitest et son module de couverture seront ajoutés en dépendances de développement."
                ))
            }
        }
        if has("Cargo.toml") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let installed = ["\(home)/.cargo/bin/cargo-llvm-cov", "/opt/homebrew/bin/cargo-llvm-cov", "/usr/local/bin/cargo-llvm-cov"]
                .contains { fm.isExecutableFile(atPath: $0) }
            return CoverageSetup(tool: "cargo llvm-cov", command: CommandSpec("cargo", ["llvm-cov", "--lcov", "--output-path", "target/llvm-cov/lcov.info"], in: project),
                                 reports: ["target/llvm-cov/lcov.info"] + knownReports,
                                 missing: installed ? nil : CoverageSetup.Missing(
                                    package: "cargo-llvm-cov", install: CommandSpec("cargo", ["install", "cargo-llvm-cov", "--locked"]), global: true,
                                    why: "La couverture Rust passe par cargo-llvm-cov, un outil installé une fois pour tous les projets (~/.cargo/bin)."))
        }
        if has("pyproject.toml") || has("setup.py") || has("requirements.txt") || has("pytest.ini") {
            let runner: [String] = has("uv.lock") ? ["uv", "run"] : has("poetry.lock") ? ["poetry", "run"] : []
            let args = ["pytest", "--cov", "--cov-report=xml"]
            let spec = runner.isEmpty ? CommandSpec("pytest", Array(args.dropFirst()), in: project) : CommandSpec(runner[0], Array(runner.dropFirst()) + args, in: project)
            let declared = ["pyproject.toml", "requirements.txt", "requirements-dev.txt", "setup.py", "uv.lock", "poetry.lock"]
                .contains { text($0).contains("pytest-cov") }
            var missing: CoverageSetup.Missing?
            if !declared {
                let install: CommandSpec? = has("uv.lock") ? CommandSpec("uv", ["add", "--dev", "pytest-cov"], in: project)
                    : has("poetry.lock") ? CommandSpec("poetry", ["add", "--group", "dev", "pytest-cov"], in: project) : nil
                if let install {
                    missing = CoverageSetup.Missing(package: "pytest-cov", install: install,
                                                    why: "pytest-cov n’est pas dans les dépendances du projet : sans lui, « pytest --cov » échoue.")
                }
            }
            return CoverageSetup(tool: "pytest-cov", command: spec, reports: ["coverage.xml"] + knownReports, missing: missing)
        }
        if has("go.mod") {
            return CoverageSetup(tool: "go cover", command: CommandSpec("go", ["test", "-coverprofile=coverage.out", "./..."], in: project),
                                 reports: ["coverage.out"] + knownReports)
        }
        if has("pom.xml") {
            let tool = has("mvnw") ? "./mvnw" : "mvn"
            return CoverageSetup(tool: "JaCoCo", command: CommandSpec(tool, ["verify", "jacoco:report"], in: project),
                                 reports: ["target/site/jacoco/jacoco.xml"] + knownReports)
        }
        if has("build.gradle") || has("build.gradle.kts") {
            let tool = has("gradlew") ? "./gradlew" : "gradle"
            return CoverageSetup(tool: "JaCoCo", command: CommandSpec(tool, ["test", "jacocoTestReport"], in: project),
                                 reports: ["build/reports/jacoco/test/jacocoTestReport.xml"] + knownReports)
        }
        if has("Package.swift") {
            return CoverageSetup(tool: "swift test (llvm-cov)", command: CommandSpec("swift", ["test", "--enable-code-coverage"], in: project),
                                 reports: [".build/debug/codecov", ".build/out/Products/Debug/codecov", ".build/arm64-apple-macosx/debug/codecov"] + knownReports)
        }
        // Pas d'outil reconnu, mais peut-être un rapport existant.
        let existing = knownReports.filter(has)
        return existing.isEmpty ? nil : CoverageSetup(tool: "Rapport existant", command: nil, reports: existing)
    }

    /// Version demandée pour un paquet dans package.json (« ^2.1.8 »).
    static func requirement(of name: String, in json: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        for key in ["devDependencies", "dependencies"] {
            if let value = (object[key] as? [String: Any])?[name] as? String { return value }
        }
        return nil
    }

    /// Ajout de l'outil manquant, avec ou sans mesure juste après.
    public static func installPlan(project: URL, setup: CoverageSetup, thenRun: Bool) -> ActionPlan? {
        guard let missing = setup.missing else { return nil }
        var commands = [missing.install]
        if thenRun, let command = setup.command { commands.append(command) }
        return ActionPlan(
            title: thenRun ? "Ajouter \(missing.package) et mesurer la couverture" : "Ajouter \(missing.package) à \(project.lastPathComponent)",
            summary: missing.why + (missing.global ? " L’outil est installé pour votre compte, pas dans le projet."
                                                   : " Le manifeste et le lockfile du projet seront modifiés."),
            kind: .commande, risk: .caution, reversible: false, commands: commands
        )
    }

    /// Lit le rapport le plus récent parmi les emplacements connus.
    public static func read(project: URL, setup: CoverageSetup) -> CoverageReport? {
        let fm = FileManager.default
        var candidates: [(URL, Date)] = []
        for relative in setup.reports {
            let url = project.appendingPathComponent(relative)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                // .build/debug/codecov/<paquet>.json
                for file in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where file.pathExtension == "json" {
                    candidates.append((file, modified(file)))
                }
            } else {
                candidates.append((url, modified(url)))
            }
        }
        for (url, date) in candidates.sorted(by: { $0.1 > $1.1 }) {
            if let report = parse(url, project: project, date: date) { return report }
        }
        return nil
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    static func parse(_ url: URL, project: URL, date: Date) -> CoverageReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let relative = CoverageParser.relative(url.path, project)
        let name = url.lastPathComponent
        func report(_ format: CoverageReport.Format, _ r: (lines: Double, branches: Double?, functions: Double?, files: [FileCoverage])?) -> CoverageReport? {
            r.map { CoverageReport(format: format, file: relative, date: date, lines: $0.lines, branches: $0.branches, functions: $0.functions, files: $0.files) }
        }
        if url.pathExtension == "json" { return report(.llvmJSON, CoverageParser.llvmJSON(data, root: project)) }
        let text = String(decoding: data, as: UTF8.self)
        if url.pathExtension == "info" { return report(.lcov, CoverageParser.lcov(text, root: project)) }
        if name.hasSuffix(".out") {
            let module = (try? String(contentsOf: project.appendingPathComponent("go.mod"), encoding: .utf8))?
                .split(separator: "\n").first { $0.hasPrefix("module ") }.map { String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            return report(.goProfile, CoverageParser.goProfile(text, module: module))
        }
        if text.contains("<report") && text.contains("<counter ") { return report(.jacoco, CoverageParser.jacoco(text)) }
        if text.contains("<coverage ") { return report(.cobertura, CoverageParser.cobertura(text, root: project)) }
        return nil
    }

    /// Plan d'exécution des tests avec couverture (aperçu obligatoire : la commande est affichée).
    public static func runPlan(project: URL, setup: CoverageSetup) -> ActionPlan? {
        guard let command = setup.command else { return nil }
        return ActionPlan(
            title: "Mesurer la couverture de \(project.lastPathComponent)",
            summary: "Lance les tests du projet avec \(setup.tool). Le rapport est écrit dans le projet (dossier de build ou coverage/), puis relu ici.",
            kind: .commande, risk: .safe, reversible: true, commands: [command]
        )
    }
}

/// Historique des mesures, pour la tendance.
public struct CoverageHistory: Sendable, Codable {
    public struct Point: Sendable, Codable, Hashable {
        public var date: Date
        public var lines: Double
        public var branches: Double?
        public var functions: Double?
    }

    public var projects: [String: [Point]] = [:]

    public init() {}

    /// Ajoute la mesure si elle est nouvelle (date du rapport différente).
    public mutating func record(_ report: CoverageReport, project: URL) -> Bool {
        var points = projects[project.path] ?? []
        guard !points.contains(where: { abs($0.date.timeIntervalSince(report.date)) < 1 }) else { return false }
        points.append(Point(date: report.date, lines: report.lines, branches: report.branches, functions: report.functions))
        points.sort { $0.date < $1.date }
        projects[project.path] = Array(points.suffix(50))
        return true
    }

    /// Écart avec la mesure précédente, en points.
    public func trend(project: URL) -> Double? {
        guard let points = projects[project.path], points.count >= 2 else { return nil }
        return points[points.count - 1].lines - points[points.count - 2].lines
    }
}
