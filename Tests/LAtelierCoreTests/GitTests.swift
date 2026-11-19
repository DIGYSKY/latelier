import Foundation
import Testing
@testable import LAtelierCore

/// Dépôt git jetable.
private func makeRepo(_ box: Sandbox, _ name: String) async throws -> URL {
    let repo = box.dir(name)
    let runner = CommandRunner()
    let env = ["GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "t@example.com",
               "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "t@example.com"]
    func git(_ args: String...) async throws {
        let result = try await runner.run(CommandSpec("git", Array(args), in: repo, environment: env))
        #expect(result.succeeded, "git \(args.joined(separator: " ")) : \(result.stderr)")
    }
    try await git("init", "-q", "-b", "main")
    box.file("\(name)/package.json")
    box.file("\(name)/tsconfig.json")
    box.file("\(name)/a.txt", bytes: 3)
    try await git("add", ".")
    try await git("commit", "-q", "-m", "premier commit")
    try await git("branch", "ancienne")
    return repo
}

@Suite struct GitTests {
    @Test func readsStatusOfARealRepository() async throws {
        let box = Sandbox()
        let repo = try await makeRepo(box, "app")
        box.file("app/a.txt", bytes: 20)                 // modifié
        box.file("app/nouveau dossier/b.txt")            // non suivi, avec espace
        let status = await GitClient().status(of: repo)

        #expect(status.error == nil)
        #expect(status.branch == "main")
        #expect(status.languages == ["TypeScript"])
        #expect(status.state == .modified)
        #expect(Set(status.changes.map(\.path)) == ["a.txt", "nouveau dossier/"])
        let modified = status.changes.first { $0.path == "a.txt" }!
        #expect(modified.code == "M" && !modified.staged)
        #expect(status.recentCommits.first?.subject == "premier commit")
        #expect(status.branches.map(\.name) == ["main", "ancienne"])
        #expect(status.branches[1].merged)
        #expect(!status.hasRemote)
    }

    @Test func commitPlanCommitsOnlyChosenFiles() async throws {
        let box = Sandbox()
        let repo = try await makeRepo(box, "app")
        box.file("app/a.txt", bytes: 20)
        box.file("app/garder.txt")
        box.file("app/nouveau.txt")
        let git = GitClient()
        let before = await git.status(of: repo)
        let chosen = before.changes.filter { $0.path != "garder.txt" }
        let plan = GitClient.commitPlan(before, files: chosen, message: "  deuxième  ")!
        let entry = await PlanExecutor(safety: SafetyGuard(root: box.root)).execute(plan)
        #expect(entry.outcome == .success, "\(entry.commands.map(\.output))")

        let after = await git.status(of: repo)
        #expect(after.changes.map(\.path) == ["garder.txt"])
        #expect(after.recentCommits.first?.subject == "deuxième")
    }

    @Test func parsesAheadBehindAndRenames() {
        var status = RepoStatus(url: URL(fileURLWithPath: "/x"), languages: [])
        GitClient.parseStatus([
            "# branch.oid abc", "# branch.head feature/x", "# branch.upstream origin/feature/x", "# branch.ab +2 -1",
            "2 R. N... 100644 100644 100644 aaa bbb R100 nouveau nom.txt\tancien.txt",
            "u UU N... 100644 100644 100644 100644 a b c conflit.txt",
        ], into: &status)
        #expect(status.branch == "feature/x" && status.ahead == 2 && status.behind == 1)
        #expect(status.changes[0].path == "nouveau nom.txt" && status.changes[0].originalPath == "ancien.txt" && status.changes[0].staged)
        #expect(status.changes[1].isConflict)
        #expect(status.state == .conflict)
    }

    @Test func parsesBranchTracking() {
        let branches = GitClient.parseBranches([
            "main\u{1F}origin/main\u{1F}ahead 3, behind 2\u{1F}*",
            "vieille\u{1F}origin/vieille\u{1F}gone\u{1F} ",
        ], merged: ["vieille"])
        #expect(branches[0].isCurrent && branches[0].ahead == 3 && branches[0].behind == 2)
        #expect(branches[1].upstreamGone && branches[1].merged)
    }

    @Test func findsRepositoriesWithoutDescendingIntoThem() async throws {
        let box = Sandbox()
        _ = try await makeRepo(box, "a")
        _ = try await makeRepo(box, "groupe/b")
        box.dir("a/sous-module/.git")          // dans un dépôt : ignoré
        box.dir("node_modules/x/.git")         // dossier exclu
        let found = RepoScanner(roots: [box.root]).repositories().map(\.lastPathComponent)
        #expect(found == ["a", "b"])
    }

    @Test func fetchAllKeepsGoingAfterAFailure() async throws {
        let box = Sandbox()
        let repo = try await makeRepo(box, "app")
        let status = await GitClient().status(of: repo)
        let broken = RepoStatus(url: box.root.appendingPathComponent("absent"), languages: [])
        let plan = GitClient.fetchPlan([broken, status])
        let entry = await PlanExecutor(safety: SafetyGuard(root: box.root)).execute(plan)
        #expect(entry.commands.count == 2)
        guard case .partial = entry.outcome else {
            Issue.record("attendu .partial, obtenu \(entry.outcome)")
            return
        }
    }
}
