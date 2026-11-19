import Foundation
import Testing
@testable import LAtelierCore

@Suite struct ShellQuoteTests {
    @Test func leavesSafeWordsAlone() {
        #expect(ShellQuote.quote("git") == "git")
        #expect(ShellQuote.quote("--version") == "--version")
    }

    @Test func quotesSpacesAndApostrophes() {
        #expect(ShellQuote.quote("a b") == "'a b'")
        #expect(ShellQuote.quote("L’Atelier") == "'L’Atelier'")
        #expect(ShellQuote.quote("it's") == "'it'\\''s'")
        #expect(ShellQuote.quote("") == "''")
    }

    @Test func displayStringIncludesDirectory() {
        let spec = CommandSpec("git", ["commit", "-m", "premier jet"], in: URL(fileURLWithPath: "/tmp/mon projet"))
        #expect(spec.displayString == "cd '/tmp/mon projet' && git commit -m 'premier jet'")
    }
}

@Suite struct CommandRunnerTests {
    let runner = CommandRunner()

    @Test func capturesStdoutAndStatus() async throws {
        let result = try await runner.run(CommandSpec("/bin/echo", ["bonjour", "l’atelier"]))
        #expect(result.exitStatus == 0)
        #expect(result.stdout == ["bonjour l’atelier"])
    }

    @Test func separatesStderrAndReportsFailure() async throws {
        let result = try await runner.run(CommandSpec("/bin/sh", ["-c", "echo oups >&2; exit 3"]))
        #expect(result.exitStatus == 3)
        #expect(result.stderr == ["oups"])
        #expect(result.stdout.isEmpty)
    }

    @Test func splitsLinesAndKeepsLastPartialLine() async throws {
        let result = try await runner.run(CommandSpec("/usr/bin/printf", ["un\\ndeux\\r\\ntrois"]))
        #expect(result.stdout == ["un", "deux", "trois"])
    }

    @Test func usesWorkingDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let result = try await runner.run(CommandSpec("/bin/pwd", in: dir))
        #expect(result.stdout.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } == dir)
    }

    @Test func missingToolThrows() async {
        await #expect(throws: CommandError.toolNotFound("outil-qui-n-existe-pas")) {
            try await runner.run(CommandSpec("outil-qui-n-existe-pas"))
        }
    }

    @Test func timeoutKillsLongCommand() async {
        let start = Date()
        await #expect(throws: CommandError.self) {
            try await runner.run(CommandSpec("/bin/sleep", ["30"]), timeout: .milliseconds(300))
        }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func locatesToolsByName() {
        #expect(ToolLocator.standard.locate("sh")?.path == "/bin/sh")
    }
}

@Suite struct PlanExecutorTests {
    let executor = PlanExecutor()

    func plan(_ commands: [CommandSpec]) -> ActionPlan {
        ActionPlan(title: "Test", summary: "", kind: .commande, risk: .safe, reversible: true, commands: commands)
    }

    @Test func successRunsEverything() async {
        let entry = await executor.execute(plan([
            CommandSpec("/bin/echo", ["un"]), CommandSpec("/bin/echo", ["deux"]),
        ]))
        #expect(entry.outcome == .success)
        #expect(entry.commands.map(\.output) == ["un", "deux"])
    }

    @Test func stopsAtFirstFailureAndSaysPartial() async {
        let entry = await executor.execute(plan([
            CommandSpec("/bin/echo", ["un"]),
            CommandSpec("/bin/sh", ["-c", "exit 1"]),
            CommandSpec("/bin/echo", ["jamais"]),
        ]))
        #expect(entry.commands.count == 2)
        guard case .partial(let message) = entry.outcome else {
            Issue.record("attendu .partial, obtenu \(entry.outcome)")
            return
        }
        #expect(message.contains("1 commande(s) sur 3"))
    }

    @Test func firstFailureIsFailure() async {
        let entry = await executor.execute(plan([CommandSpec("outil-absent")]))
        guard case .failure = entry.outcome else {
            Issue.record("attendu .failure, obtenu \(entry.outcome)")
            return
        }
    }

    @Test func cancellationStopsProcess() async {
        let task = Task { await executor.execute(plan([CommandSpec("/bin/sleep", ["30"])])) }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let entry = await task.value
        #expect(entry.outcome == .cancelled)
    }

    @Test func outputTailKeepsTheEnd() {
        var tail = OutputTail(limit: 10)
        for i in 0..<100 { tail.append("ligne \(i)") }
        #expect(tail.text.hasPrefix("…\n"))
        #expect(tail.text.hasSuffix("ligne 99"))
    }
}

@Suite struct HistoryStoreTests {
    @Test func roundTripsNewestFirst() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = HistoryStore(fileURL: url, limit: 2)
        try await store.append(HistoryEntry(kind: .git, title: "A", outcome: .success))
        try await store.append(HistoryEntry(kind: .paquet, title: "B", outcome: .partial("moitié")))
        try await store.append(HistoryEntry(kind: .nettoyage, title: "C", outcome: .failure("non"), bytesFreed: 42))

        let reloaded = try await HistoryStore(fileURL: url).all()
        #expect(reloaded.map(\.title) == ["C", "B"])
        #expect(reloaded[1].outcome == .partial("moitié"))
        #expect(reloaded[0].bytesFreed == 42)
    }
}
