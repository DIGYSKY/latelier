import Foundation
import Testing
@testable import LAtelierCore

/// Arborescence jetable, effacée à la fin du test.
final class Sandbox {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("latelier-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func file(_ path: String, bytes: Int = 10, modified: Date? = nil) -> URL {
        let url = root.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(repeating: 0x41, count: bytes).write(to: url)
        if let modified { try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    @discardableResult
    func dir(_ path: String) -> URL {
        let url = root.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite struct SafetyGuardTests {
    let home = URL(fileURLWithPath: "/Users/test")
    var safety: SafetyGuard { SafetyGuard(root: home) }

    @Test func allowsItemsInsideHome() throws {
        try safety.check(URL(fileURLWithPath: "/Users/test/Library/Caches/com.spotify.client"))
        try safety.check(URL(fileURLWithPath: "/Users/test/projects/shop/node_modules"))
    }

    @Test func refusesOutsideHome() {
        #expect(throws: SafetyGuard.Refusal.self) { try safety.check(URL(fileURLWithPath: "/System/Library")) }
        #expect(throws: SafetyGuard.Refusal.self) { try safety.check(URL(fileURLWithPath: "/Users/other/x")) }
        #expect(throws: SafetyGuard.Refusal.self) { try safety.check(URL(fileURLWithPath: "/Users/test")) }
        #expect(throws: SafetyGuard.Refusal.self) { try safety.check(URL(fileURLWithPath: "/Users/test/../other/x")) }
    }

    @Test func refusesProtectedFolders() {
        for path in ["Library", "Library/Caches", "Documents", "projects", ".ssh/id_ed25519", "Library/Keychains/login.keychain-db"] {
            #expect(throws: SafetyGuard.Refusal.self, "\(path)") {
                try safety.check(home.appendingPathComponent(path))
            }
        }
    }
}

@Suite struct RemovalTests {
    @Test func removesPermanentlyAndCountsBytes() async {
        let box = Sandbox()
        let a = box.file("a/cache.bin", bytes: 4096)
        let b = box.dir("b")
        let executor = PlanExecutor(safety: SafetyGuard(root: box.root))
        let plan = ActionPlan(
            title: "Test", summary: "", kind: .nettoyage, risk: .safe, reversible: false,
            steps: [.remove(a, bytes: 4096, permanently: true), .remove(b, bytes: 10, permanently: true)]
        )
        let entry = await executor.execute(plan)
        #expect(entry.outcome == .success)
        #expect(entry.bytesFreed == 4106)
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(entry.commands.count == 1)
        #expect(entry.commands[0].command == "Suppression définitive de 2 élément(s)")
    }

    @Test func refusedItemIsReportedAndOthersContinue() async {
        let box = Sandbox()
        let ok = box.file("ok.txt")
        let executor = PlanExecutor(safety: SafetyGuard(root: box.root))
        let plan = ActionPlan(
            title: "Test", summary: "", kind: .nettoyage, risk: .safe, reversible: false,
            steps: [.remove(URL(fileURLWithPath: "/etc/hosts"), bytes: 1, permanently: true), .remove(ok, bytes: 10, permanently: true)]
        )
        let entry = await executor.execute(plan)
        guard case .partial = entry.outcome else {
            Issue.record("attendu .partial, obtenu \(entry.outcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: "/etc/hosts"))
        #expect(!FileManager.default.fileExists(atPath: ok.path))
        #expect(entry.commands[0].output.contains("✗ /etc/hosts"))
    }

    @Test func switchingMethodChangesEverySteps() {
        let plan = ActionPlan(
            title: "T", summary: "", kind: .nettoyage, risk: .safe, reversible: true,
            steps: [.remove(URL(fileURLWithPath: "/tmp/a"), bytes: 1, permanently: false)]
        )
        let permanent = plan.removing(permanently: true)
        #expect(permanent.removesPermanently)
        #expect(!permanent.reversible)
        #expect(permanent.removing(permanently: false).reversible)
    }
}

@Suite struct DevArtifactScannerTests {
    @Test func findsArtifactsGroupedByProject() async {
        let box = Sandbox()
        let old = Date(timeIntervalSinceNow: -200 * 86_400)
        box.file("old-shop/package.json", modified: old)
        box.file("old-shop/node_modules/react/index.js", bytes: 5000)
        box.file("old-shop/.next/cache/x", bytes: 3000)
        box.file("rusty/Cargo.toml")
        box.file("rusty/target/debug/app", bytes: 8000)
        box.file("notrust/target/keep.txt", bytes: 100)            // pas de Cargo.toml : ce n'est pas un artefact
        box.file("py/pyproject.toml")
        box.file("py/.venv/pyvenv.cfg")
        box.file("py/src/__pycache__/a.pyc", bytes: 700)
        box.file("old-shop/node_modules/dep/node_modules/x/i.js") // imbriqué : déjà compté

        let scanner = DevArtifactScanner(roots: [box.root], busyDirectories: [box.root.appendingPathComponent("py/src").path])
        let groups = await scanner.scan()
        let items = groups.flatMap(\.items)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })

        #expect(Set(byName.keys) == ["old-shop", "rusty", "py"])
        #expect(byName["old-shop"]!.entries.count == 2)
        #expect(byName["old-shop"]!.selectedByDefault)
        #expect(groups.first { $0.id == "old" }?.items.map(\.name) == ["old-shop"])
        #expect(byName["rusty"]!.kinds == ["target"])
        #expect(!byName["rusty"]!.selectedByDefault)
        #expect(byName["py"]!.isLocked)
        #expect(byName["py"]!.kinds == ["python"])
        #expect(byName["old-shop"]!.filtered(kind: "node")!.entries.count == 1)
    }

    @Test func planSkipsLockedItems() {
        let a = CleanupItem(id: "a", name: "a", detail: "", entries: [.init(url: URL(fileURLWithPath: "/x/a"), bytes: 5)])
        var b = CleanupItem(id: "b", name: "b", detail: "", entries: [.init(url: URL(fileURLWithPath: "/x/b"), bytes: 7)])
        b.lockReason = "ouvert"
        let plan = CleanupPlanner.plan(title: "T", items: [a, b], skipped: [b])!
        #expect(plan.removals.map(\.url.path) == ["/x/a"])
        #expect(plan.estimatedBytes == 5)
        #expect(plan.skipped == ["b : ouvert"])
        #expect(plan.reversible)
    }
}

@Suite struct SystemScannerTests {
    @Test func groupsSmallCachesAndProtectsOpenApps() async {
        let box = Sandbox()
        box.file("Library/Caches/com.big.app/data", bytes: 300_000)
        box.file("Library/Caches/com.small.app/data", bytes: 1000)
        box.file("Library/Caches/com.running.app/data", bytes: 200_000)
        box.file("Library/Caches/com.apple.Safari/data", bytes: 1000)
        box.file("Library/Logs/App/a.log", bytes: 500)
        box.file("Library/Logs/DiagnosticReports/crash.ips", bytes: 500)

        var scanner = SystemScanner(home: box.root, runningBundleIDs: ["com.running.app"]) { $0 == "com.big.app" ? "Big" : nil }
        scanner.smallThreshold = 100_000
        let groups = await scanner.scan()

        let caches = groups.first { $0.id == "caches" }!.items
        #expect(caches.map(\.name) == ["Big", "com.running.app", "Autres caches", "Caches de macOS"])
        #expect(caches[1].isLocked && caches[3].isLocked)
        #expect(caches[2].entries.count == 1)
        let logs = groups.first { $0.id == "logs" }!.items
        #expect(logs.map(\.name) == ["Logs d’apps", "Rapports de diagnostic"])
        #expect(groups.contains { $0.id == "trash" } == false)  // pas de corbeille dans le bac à sable
    }
}

@Suite struct ProcessDirectoriesTests {
    @Test func ignoresShells() {
        let lines = ["p1", "czsh", "fcwd", "n/Users/x/projects/a", "p2", "cnode", "fcwd", "n/Users/x/projects/b"]
        #expect(ProcessDirectories.parse(lines) == ["/Users/x/projects/b"])
    }
}
