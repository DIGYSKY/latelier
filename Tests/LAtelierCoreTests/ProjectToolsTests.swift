import Foundation
import Testing
@testable import LAtelierCore

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("latelier-tools-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct CommandsTests {
    @Test func categories() {
        #expect(CommandCategory.guess(name: "dev") == .run)
        #expect(CommandCategory.guess(name: "start:prod") == .run)
        #expect(CommandCategory.guess(name: "test:e2e") == .test)
        #expect(CommandCategory.guess(name: "lint:fix") == .quality)
        #expect(CommandCategory.guess(name: "typecheck") == .quality)
        #expect(CommandCategory.guess(name: "build") == .build)
        #expect(CommandCategory.guess(name: "deploy-staging") == .deploy)
        #expect(CommandCategory.guess(name: "ci", body: "vitest run") == .test)
        #expect(CommandCategory.guess(name: "postinstall") == .other)
    }

    @Test func sensitive() {
        let deploy = ProjectCommand(name: "deploy-staging", spec: CommandSpec("make", ["deploy-staging"]), source: "Makefile", category: .deploy)
        #expect(deploy.isSensitive)
        let migrate = ProjectCommand(name: "db", spec: CommandSpec("npm", ["run", "db"]), source: "package.json", category: .other, body: "prisma migrate deploy")
        #expect(migrate.isSensitive)
        let dev = ProjectCommand(name: "dev", spec: CommandSpec("npm", ["run", "dev"]), source: "package.json", category: .run, body: "vite")
        #expect(!dev.isSensitive)
        #expect(dev.commandLine == "npm run dev")
    }

    @Test func detectsEverything() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        {
          "name": "web",
          "packageManager": "pnpm@9.1.0",
          "scripts": {
            "dev": "vite",
            "build": "vite build",
            "test": "vitest run"
          },
          "devDependencies": { "eslint": "^9", "vitest": "^2", "typescript": "^5" }
        }
        """.write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try """
        .PHONY: test deploy
        VAR := 1
        build: deps
        \tgo build
        deploy-staging:
        \t./deploy.sh
        %.o: %.c
        \tcc
        """.write(to: dir.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        try """
        set dotenv-load
        default:
          just --list
        @lint *args:
          cargo clippy
        _hidden:
          echo
        """.write(to: dir.appendingPathComponent("justfile"), atomically: true, encoding: .utf8)
        try """
        services:
          postgres:
            image: postgres:16
          redis:
            image: redis
        volumes:
          data:
        """.write(to: dir.appendingPathComponent("docker-compose.yml"), atomically: true, encoding: .utf8)

        let set = ProjectCommandDetector.detect(dir)
        let ids = set.commands.map(\.id)
        #expect(ids.prefix(3) == ["package.json:dev", "package.json:build", "package.json:test"])
        #expect(set.commands[0].spec == CommandSpec("pnpm", ["run", "dev"], in: dir))
        #expect(ids.contains("Makefile:build"))
        #expect(ids.contains("Makefile:deploy-staging"))
        #expect(!ids.contains { $0.hasPrefix("Makefile:%") || $0 == "Makefile:VAR" || $0 == "Makefile:.PHONY" })
        #expect(ids.contains("justfile:default"))
        #expect(ids.contains("justfile:lint"))
        #expect(!ids.contains("justfile:_hidden") && !ids.contains("justfile:set"))
        #expect(ids.contains("compose:postgres") && ids.contains("compose:redis") && !ids.contains("compose:data"))
        #expect(set.sources == ["package.json", "Makefile", "justfile", "docker-compose.yml"])
        #expect(set.commands.first { $0.id == "Makefile:deploy-staging" }?.category == .deploy)
        #expect(Set(set.suggestions.map(\.kind)) == [.addLint, .addCoverage, .addTypecheck])
    }

    @Test func addsScriptKeepingFormat() throws {
        let json = """
        {
          "name": "web",
          "scripts": {
            "dev": "vite",
            "test": "vitest run"
          },
          "dependencies": {}
        }
        """
        let edit = try #require(ProjectCommandDetector.addScript("lint", "eslint .", to: json, file: URL(fileURLWithPath: "/tmp/package.json")))
        #expect(edit.after == """
        {
          "name": "web",
          "scripts": {
            "dev": "vite",
            "test": "vitest run",
            "lint": "eslint ."
          },
          "dependencies": {}
        }
        """)
        #expect(edit.added == ["\"lint\": \"eslint .\""])
        // JSON toujours valide.
        #expect((try? JSONSerialization.jsonObject(with: Data(edit.after.utf8))) != nil)

        let empty = try #require(ProjectCommandDetector.addScript("lint", "eslint .", to: "{\n  \"scripts\": {}\n}", file: URL(fileURLWithPath: "/tmp/p.json")))
        #expect((try? JSONSerialization.jsonObject(with: Data(empty.after.utf8)) as? [String: Any])?["scripts"] as? [String: String] == ["lint": "eslint ."])
    }

    @Test func otherParsers() {
        #expect(ProjectCommandDetector.taskfileTasks("""
        version: '3'
        tasks:
          build:
            cmds:
              - go build
          test:
            cmds: [go test]
        vars:
          X: 1
        """) == ["build", "test"])
        let py = ProjectCommandDetector.pythonScripts("""
        [project]
        name = "x"
        [project.scripts]
        serve = "app.main:run"
        [tool.ruff]
        line-length = 100
        """)
        #expect(py.map(\.0) == ["serve"])
    }

    @Test func busyPort() {
        #expect(CommandState.busyPort(in: ["Error: listen EADDRINUSE: address already in use :::5173"]) == 5173)
        #expect(CommandState.busyPort(in: ["Port 8080 is already in use"]) == 8080)
        #expect(CommandState.busyPort(in: ["all good"]) == nil)
    }

    @Test func editFileStep() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("package.json")
        try "{\"scripts\": {}}".write(to: file, atomically: true, encoding: .utf8)
        let edit = FileEdit(file: file, before: "{\"scripts\": {}}", after: "{\"scripts\": {\"lint\": \"eslint .\"}}", added: ["\"lint\": \"eslint .\""])
        let plan = ActionPlan(title: "Ajouter lint", summary: "", kind: .commande, risk: .safe, reversible: false, steps: [.editFile(edit)])
        let executor = PlanExecutor(safety: SafetyGuard(root: dir))
        let entry = await executor.execute(plan)
        #expect(entry.outcome == .success)
        #expect(try String(contentsOf: file, encoding: .utf8) == edit.after)
        // Le fichier a changé depuis l'aperçu : rien n'est écrit.
        let again = await executor.execute(plan)
        if case .failure(let reason) = again.outcome { #expect(reason.contains("a changé")) } else { Issue.record("attendu : échec") }
        #expect(plan.steps[0].displayString == "modifier package.json : + \"lint\": \"eslint .\"")
    }

    @Test func stopsWholeTree() async throws {
        // sh lance sleep : arrêter le flux doit tuer les deux.
        let runner = CommandRunner()
        let task = Task {
            for try await _ in runner.stream(CommandSpec("/bin/sh", ["-c", "sleep 31 & sleep 31; wait"])) {}
        }
        try await Task.sleep(for: .milliseconds(400))
        let me = getpid()
        let before = ProcessTree.descendants(of: me).filter { ProcessTree.arguments(of: $0) == ["sleep", "31"] }
        #expect(before.count == 2)
        task.cancel()
        try await Task.sleep(for: .milliseconds(600))
        let after = before.filter { ProcessSampler.bsdInfo($0) != nil }
        #expect(after.isEmpty)
    }
}

@Suite struct CoverageTests {
    @Test func lcov() throws {
        let text = """
        TN:
        SF:/p/src/a.ts
        FNF:4
        FNH:2
        DA:1,1
        DA:2,0
        LF:10
        LH:8
        BRF:4
        BRH:1
        end_of_record
        SF:/p/src/b.ts
        DA:1,0
        DA:2,0
        DA:3,5
        end_of_record
        """
        let r = try #require(CoverageParser.lcov(text, root: URL(fileURLWithPath: "/p")))
        #expect(abs(r.lines - 9.0 / 13.0 * 100) < 0.01)
        #expect(r.branches == 25)
        #expect(r.functions == 50)
        #expect(r.files.map(\.path) == ["src/a.ts", "src/b.ts"])
        #expect(r.files[1].linesCovered == 1 && r.files[1].linesTotal == 3)
    }

    @Test func cobertura() throws {
        let xml = """
        <?xml version="1.0" ?>
        <coverage version="7.4" line-rate="0.75" branch-rate="0.5" branches-valid="4" lines-valid="8">
          <packages><package name="app"><classes>
            <class name="a.py" filename="app/a.py" line-rate="1"><lines><line number="1" hits="1"/><line number="2" hits="3"/></lines></class>
            <class name="b.py" filename="app/b.py" line-rate="0.5"><lines><line number="1" hits="0"/><line number="2" hits="1"/></lines></class>
          </classes></package></packages>
        </coverage>
        """
        let r = try #require(CoverageParser.cobertura(xml))
        #expect(r.lines == 75)
        #expect(r.branches == 50)
        #expect(r.files.count == 2)
        #expect(r.files[1].percent == 50)
    }

    @Test func jacoco() throws {
        let xml = """
        <report name="gw"><package name="com/gw">
        <class name="com/gw/A"><counter type="LINE" missed="1" covered="1"/></class>
        <sourcefile name="RateLimiter.java"><counter type="LINE" missed="109" covered="31"/><counter type="BRANCH" missed="3" covered="1"/></sourcefile>
        <counter type="LINE" missed="109" covered="31"/>
        </package>
        <counter type="INSTRUCTION" missed="10" covered="90"/><counter type="BRANCH" missed="36" covered="64"/>
        <counter type="LINE" missed="22" covered="78"/><counter type="METHOD" missed="17" covered="83"/>
        </report>
        """
        let r = try #require(CoverageParser.jacoco(xml))
        #expect(r.lines == 78)
        #expect(r.branches == 64)
        #expect(r.functions == 83)
        #expect(r.files.first?.path == "com/gw/RateLimiter.java")
        #expect(r.files.first?.linesTotal == 140)
    }

    @Test func llvmJSON() throws {
        let json = """
        {"data":[{"files":[
          {"filename":"/p/Sources/A.swift","summary":{"lines":{"count":100,"covered":60,"percent":60}}},
          {"filename":"/p/Tests/ATests.swift","summary":{"lines":{"count":50,"covered":50,"percent":100}}},
          {"filename":"/p/.build/checkouts/x/B.swift","summary":{"lines":{"count":10,"covered":0,"percent":0}}}
        ],"totals":{"lines":{"count":160,"covered":110,"percent":68.75},"functions":{"count":10,"covered":7,"percent":70},"branches":{"count":0,"covered":0,"percent":0}}}]}
        """
        let r = try #require(CoverageParser.llvmJSON(Data(json.utf8), root: URL(fileURLWithPath: "/p")))
        #expect(r.lines == 60)
        #expect(r.functions == 70)
        #expect(r.branches == nil)
        #expect(r.files.map(\.path) == ["Sources/A.swift"])
    }

    @Test func goProfile() throws {
        let text = """
        mode: set
        example.com/app/main.go:5.13,7.2 2 1
        example.com/app/main.go:9.13,11.2 3 0
        example.com/app/util/u.go:3.1,4.2 5 1
        example.com/app/util/u.go:3.1,4.2 5 1
        """
        let r = try #require(CoverageParser.goProfile(text, module: "example.com/app"))
        #expect(r.lines == 70)
        #expect(Set(r.files.map(\.path)) == ["main.go", "util/u.go"])
    }

    @Test func detectsAndReads() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{\"devDependencies\":{\"vitest\":\"^2\"}}".write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("coverage"), withIntermediateDirectories: true)
        try "SF:\(dir.path)/src/a.ts\nDA:1,1\nDA:2,0\nend_of_record\n".write(to: dir.appendingPathComponent("coverage/lcov.info"), atomically: true, encoding: .utf8)
        let setup = try #require(CoverageDetector.setup(for: dir))
        #expect(setup.tool == "Vitest")
        #expect(setup.command?.arguments.prefix(4) == ["vitest", "run", "--coverage", "--coverage.reporter=lcov"])
        let report = try #require(CoverageDetector.read(project: dir, setup: setup))
        #expect(report.format == .lcov)
        #expect(report.lines == 50)
        #expect(report.file == "coverage/lcov.info")
        #expect(report.files.first?.path == "src/a.ts")
        let plan = try #require(CoverageDetector.runPlan(project: dir, setup: setup))
        #expect(plan.commands.first?.workingDirectory == dir)

        var history = CoverageHistory()
        let first = history.record(report, project: dir)
        let duplicate = history.record(report, project: dir)
        #expect(first && !duplicate)
        var newer = report
        newer.date = report.date.addingTimeInterval(60)
        newer.lines = 62
        let added = history.record(newer, project: dir)
        #expect(added)
        #expect(history.trend(project: dir) == 12)
    }

    @Test func weakestFiles() {
        let report = CoverageReport(format: .lcov, file: "x", date: Date(), lines: 50, branches: nil, functions: nil, files: [
            FileCoverage(path: "big", linesCovered: 10, linesTotal: 100),
            FileCoverage(path: "tiny", linesCovered: 0, linesTotal: 2),
            FileCoverage(path: "ok", linesCovered: 90, linesTotal: 100),
        ])
        #expect(report.weakest().map(\.path) == ["big", "ok"])
    }
}

@Suite struct LauncherTests {
    @Test func scriptQuotesEverything() {
        let script = Launcher.script(directory: URL(fileURLWithPath: "/Users/me/my project"),
                                     command: ["/usr/local/bin/claude", "Corrige l'erreur « x » ; rm -rf /"], shell: "/bin/zsh")
        #expect(script == """
        #!/bin/zsh -l
        cd '/Users/me/my project' || exit 1
        clear
        /usr/local/bin/claude 'Corrige l'\\''erreur « x » ; rm -rf /'
        exec /bin/zsh -l

        """)
        #expect(!Launcher.script(directory: URL(fileURLWithPath: "/p"), command: nil, shell: "/bin/zsh").contains("clear"))
    }

    @Test func claudeCommand() {
        let locator = ToolLocator(searchPaths: ["/nonexistent"])
        #expect(Launcher.claudeCommand(prompt: nil, locator: locator) == ["claude"])
        #expect(Launcher.claudeCommand(prompt: "  ", locator: locator) == ["claude"])
        #expect(Launcher.claudeCommand(prompt: "Corrige", locator: locator) == ["claude", "Corrige"])
    }

    @Test func prompts() {
        let prompt = ClaudePrompts.fixVulnerability(package: "next", version: "14.0.1", fixed: "14.2.25", ids: ["CVE-2025-29927"], manifest: "package.json")
        #expect(prompt.hasPrefix("Mets à jour next (actuellement 14.0.1) vers 14.2.25 ou plus pour corriger CVE-2025-29927."))
        #expect(ClaudePrompts.failedCommand("npm test", tail: ["a", "b"]).hasSuffix("a\nb"))
    }
}

@Suite struct RecorderTests {
    @Test func displayCommand() {
        let home = NSHomeDirectory()
        #expect(RecorderDetector.displayCommand(["/opt/homebrew/bin/node", "\(home)/p/node_modules/.bin/vite", "--port", "5173"])
                == "node …/.bin/vite --port 5173")
        #expect(RecorderDetector.displayCommand(["/usr/bin/python3", "\(home)/p/app.py"]) == "python3 ~/p/app.py")
        #expect(RecorderDetector.displayCommand(["node", "server.mjs", "--token", "0d6a2869bdfa6d0ea6545fdd"]) == "node server.mjs --token ••••")
        #expect(RecorderDetector.displayCommand(["app", "--api-key=abc", "sk1234567890abcdef1234567890"]) == "app --api-key=•••• ••••")
        #expect(RecorderDetector.displayCommand(["vite", "--port", "5173"]) == "vite --port 5173")
        #expect(RecorderDetector.displayCommand(["python3", "-c", "\nimport time\nwhile True:\n    time.sleep(1)\n"]) == "python3 -c import time while True: time.sleep(1)")
    }

    @Test func ownArguments() throws {
        let args = try #require(ProcessTree.arguments(of: getpid()))
        #expect(!args.isEmpty)
    }

    @Test func sessionStats() {
        var session = RecordingSession(name: "x", project: "/p/shop", command: "npm run dev", auto: true, start: Date())
        session.samples = [
            RecordingSample(t: 0, cpu: 10, memory: 100, diskRead: 0, diskWrite: 0, processes: 1),
            RecordingSample(t: 1, cpu: 30, memory: 300, diskRead: 1000, diskWrite: 0, processes: 2),
            RecordingSample(t: 2, cpu: 20, memory: 200, diskRead: 1000, diskWrite: 500, processes: 2),
        ]
        #expect(session.averageCPU == 20)
        #expect(session.maxCPU == 30)
        #expect(session.maxMemory == 300)
        #expect(session.totalRead == 2000)
        #expect(session.totalWritten == 500)
        #expect(session.duration == 2)
        #expect(session.projectName == "shop")
        var reference = session
        reference.samples = session.samples.map { var s = $0; s.cpu /= 2; return s }
        #expect(session.delta(from: reference).cpu == 100)
        session.marks = [RecordingMark(t: 1, label: "Démarrage \"ok\"", auto: false)]
        let csv = session.csv()
        #expect(csv.hasPrefix("t_s,cpu_pct,memoire_octets"))
        #expect(csv.contains("1.0,30.0,300,1000,0,2"))
        #expect(csv.contains("1.0,\"Démarrage \"\"ok\"\"\""))
    }

    @Test func autoMarks() {
        var samples = (0..<20).map { RecordingSample(t: Double($0), cpu: 10, memory: 200 << 20, diskRead: 0, diskWrite: 0, processes: 1) }
        #expect(MarkDetector.detect(samples: samples, marks: []) == nil)
        samples.append(RecordingSample(t: 20, cpu: 80, memory: 200 << 20, diskRead: 0, diskWrite: 0, processes: 1))
        let mark = MarkDetector.detect(samples: samples, marks: [])
        #expect(mark?.label == "Pic CPU détecté (80 %)")
        #expect(MarkDetector.detect(samples: samples, marks: [RecordingMark(t: 10, label: "x", auto: true)]) == nil)
        samples.append(RecordingSample(t: 21, cpu: 10, memory: 400 << 20, diskRead: 0, diskWrite: 0, processes: 1))
        #expect(MarkDetector.detect(samples: samples, marks: [])?.label == "Hausse de mémoire (+200 Mo)")
    }

    @Test func detectsChildOfOwnProcess() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = CommandRunner()
        let task = Task { for try await _ in runner.stream(CommandSpec("/bin/sleep", ["30"], in: dir)) {} }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(400))
        // Le dossier temporaire est sous /var, lien vers /private/var.
        let real = dir.path.hasPrefix("/var/") ? URL(fileURLWithPath: "/private" + dir.path) : dir
        let found = RecorderDetector.scan(projects: [real], minimumAge: 0)
        let sleep = try #require(found.first { $0.name == "sleep" })
        #expect(sleep.fromAtelier)
        #expect(sleep.command == "/bin/sleep 30".replacingOccurrences(of: "/bin/", with: ""))
        var sampler = TreeSampler(root: sleep.target)
        _ = sampler.sample()
        let second = sampler.sample(now: Date().addingTimeInterval(1))
        #expect(second?.processes == 1)
        #expect((second?.memory ?? 0) > 0)
    }

    @Test func storeRoundTrip() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecordingStore(directory: dir)
        let session = RecordingSession(name: "a", project: "/p", command: "x", auto: false, start: Date(timeIntervalSince1970: 1_700_000_000),
                                       samples: [RecordingSample(t: 0, cpu: 1, memory: 2, diskRead: 0, diskWrite: 0, processes: 1)])
        try await store.save(session)
        let loaded = await store.all()
        #expect(loaded == [session])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LATELIER_LIVE"] == "1"))
    func liveProjects() async {
        let roots = DevArtifactScanner.defaultRoots()
        let repos = await RepoScanner(roots: roots).repositories()
        print("projets", repos.count)
        var totalCommands = 0
        for repo in repos.prefix(80) {
            let set = ProjectCommandDetector.detect(repo)
            totalCommands += set.commands.count
            if let setup = CoverageDetector.setup(for: repo) {
                let report = CoverageDetector.read(project: repo, setup: setup)
                print(repo.lastPathComponent, "|", set.sources.joined(separator: ","), set.commands.count, "cmds",
                      set.suggestions.map(\.kind.rawValue), "|", setup.tool, report.map { "\(Int($0.lines))% \($0.format)" } ?? "-")
            }
        }
        print("commandes", totalCommands)
        let own = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if let setup = CoverageDetector.setup(for: own), let report = CoverageDetector.read(project: own, setup: setup) {
            print("L’Atelier", report.format, report.file, Int(report.lines), report.functions.map(Int.init) as Any, report.files.count, "fichiers",
                  report.weakest(4).map { "\($0.path) \(Int($0.percent))%" })
        }
        let detected = RecorderDetector.scan(projects: repos)
        print("processus détectés", detected.map { "\($0.project.lastPathComponent): \($0.command) (\($0.children) enfants)" })
    }
}
