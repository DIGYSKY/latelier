import Foundation
import Testing
@testable import LAtelierCore

@Suite struct DependencyChainTests {
    @Test func semverRanges() {
        #expect(SemverRange.satisfies("2.0.7", "~2.0.7") == true)
        #expect(SemverRange.satisfies("2.0.8", "~2.0.7") == true)
        #expect(SemverRange.satisfies("2.1.0", "~2.0.7") == false)
        #expect(SemverRange.satisfies("1.9.0", "1.8.3") == false)
        #expect(SemverRange.satisfies("1.8.3", "1.8.3") == true)
        #expect(SemverRange.satisfies("1.8.3", "=1.8.3") == true)
        #expect(SemverRange.satisfies("0.1.13", "~0.1.12") == true)
        #expect(SemverRange.satisfies("0.2.0", "^0.1.12") == false)
        #expect(SemverRange.satisfies("0.0.4", "^0.0.3") == false)
        #expect(SemverRange.satisfies("4.99.0", "^4.17.21") == true)
        #expect(SemverRange.satisfies("5.0.0", "^4.17.21") == false)
        #expect(SemverRange.satisfies("5.0.0-rc.1", "^4.0.0") == false)
        #expect(SemverRange.satisfies("1.5.0", ">=1.2.0 <2") == true)
        #expect(SemverRange.satisfies("2.0.0", ">=1.2.0 <2") == false)
        #expect(SemverRange.satisfies("3.1.0", "^1.0.0 || ^3.0.0") == true)
        #expect(SemverRange.satisfies("1.4.2", "1.x") == true)
        #expect(SemverRange.satisfies("1.4.2", "1.2 - 1.4") == true)
        #expect(SemverRange.satisfies("1.5.0", "1.2 - 1.4") == false)
        #expect(SemverRange.satisfies("9.9.9", "*") == true)
        #expect(SemverRange.satisfies("2.0.8", "npm:~2.0.7") == true)
        #expect(SemverRange.satisfies("1.0.0", "npm:autre@1.0.0") == nil)
        #expect(SemverRange.satisfies("1.0.0", "latest") == nil)
    }

    static let yarnClassic = """
    # yarn lockfile v1


    express@^4.21.0:
      version "4.21.2"
      resolved "https://registry.yarnpkg.com/express/-/express-4.21.2.tgz"
      dependencies:
        proxy-addr "~2.0.7"
        qs "6.13.0"
        "@scope/x" "^1.0.0"

    proxy-addr@~2.0.7:
      version "2.0.7"
      dependencies:
        forwarded "0.2.0"

    qs@6.13.0:
      version "6.13.0"

    """

    @Test func yarnRequirements() {
        let found = YarnLock.requirements(Self.yarnClassic)
        #expect(found["proxy-addr"] == [DependencyRequirement(parent: "express", parentVersion: "4.21.2", range: "~2.0.7")])
        #expect(found["@scope/x"]?.first?.range == "^1.0.0")
        #expect(found["forwarded"]?.first?.parent == "proxy-addr")
        let berry = """
        __metadata:
          version: 8

        "express@npm:^4.21.0":
          version: 4.21.2
          dependencies:
            proxy-addr: "npm:~2.0.7"
            "@scope/x": "npm:^1.0.0"
          checksum: abc
        """
        let fromBerry = YarnLock.requirements(berry)
        #expect(fromBerry["proxy-addr"] == [DependencyRequirement(parent: "express", parentVersion: "4.21.2", range: "npm:~2.0.7")])
        #expect(fromBerry["@scope/x"]?.first?.range == "npm:^1.0.0")
    }

    @Test func npmRequirements() throws {
        let lock = """
        {"lockfileVersion": 3, "packages": {
          "": {"dependencies": {"express": "^4.21.0"}},
          "node_modules/express": {"version": "4.21.2", "dependencies": {"proxy-addr": "~2.0.7"}},
          "node_modules/proxy-addr": {"version": "2.0.7"}
        }}
        """
        let found = NpmLock.requirements(Data(lock.utf8))
        #expect(found["proxy-addr"] == [DependencyRequirement(parent: "express", parentVersion: "4.21.2", range: "~2.0.7")])
        #expect(found["express"] == nil)
    }

    @Test func overrideEdits() {
        let plain = "{\n  \"name\": \"movies\",\n  \"dependencies\": {\n    \"express\": \"^4.21.0\"\n  }\n}\n"
        let added = DependencyOverride.set("proxy-addr", to: "^2.0.8", field: "resolutions", in: plain)
        #expect(added == "{\n  \"name\": \"movies\",\n  \"dependencies\": {\n    \"express\": \"^4.21.0\"\n  },\n  \"resolutions\": {\n    \"proxy-addr\": \"^2.0.8\"\n  }\n}\n")
        // Bloc existant : ajout à la suite, puis remplacement de la valeur.
        let second = added.flatMap { DependencyOverride.set("qs", to: "^6.14.1", field: "resolutions", in: $0) }
        #expect(second?.contains("\"proxy-addr\": \"^2.0.8\",\n    \"qs\": \"^6.14.1\"\n  }") == true)
        let replaced = second.flatMap { DependencyOverride.set("qs", to: "^6.15.0", field: "resolutions", in: $0) }
        #expect(replaced?.contains("\"qs\": \"^6.15.0\"") == true)
        #expect(replaced?.contains("6.14.1") == false)
        // Une clé « resolutions » imbriquée ailleurs n'est pas le bloc de premier niveau.
        let nested = "{\n  \"config\": { \"resolutions\": { \"a\": \"1\" } }\n}"
        let top = DependencyOverride.set("b", to: "^2.0.0", field: "resolutions", in: nested)
        #expect(top?.contains("\"config\": { \"resolutions\": { \"a\": \"1\" } },\n  \"resolutions\": {\n    \"b\": \"^2.0.0\"\n  }") == true)
        // npm : override imbriqué existant, on ne touche pas.
        let npmNested = "{\n  \"overrides\": { \"qs\": { \".\": \"6.0.0\" } }\n}"
        #expect(DependencyOverride.set("qs", to: "^6.14.1", field: "overrides", in: npmNested) == nil)
        // Toujours du JSON valide.
        for json in [added, second, replaced, top].compactMap({ $0 }) {
            #expect((try? JSONSerialization.jsonObject(with: Data(json.utf8))) != nil)
        }
    }

    /// Le cas du projet Movies : express 4 demande proxy-addr ~2.0.7, la faille est corrigée en 2.0.8… puis en 2.1.0.
    @Test func blockedTransitiveIsForcedNotUpgraded() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{\n  \"name\": \"movies\",\n  \"dependencies\": {\n    \"express\": \"^4.21.0\"\n  }\n}\n"
            .write(to: dir.appending(path: "package.json"), atomically: true, encoding: .utf8)
        try Self.yarnClassic.write(to: dir.appending(path: "yarn.lock"), atomically: true, encoding: .utf8)

        let manifest = try #require(DependencyReader.read(project: dir).first)
        #expect(manifest.manager == .yarn)
        let dep = try #require(manifest.dependencies.first { $0.name == "proxy-addr" })
        #expect(!dep.direct)

        func package(fixed: String) -> VulnerablePackage {
            let vuln = Vulnerability(id: "GHSA-p", aliases: [], summary: "", severity: .critical, modified: "", affected: [])
            let finding = VulnerabilityFinding(
                project: dir, projectName: "movies", file: "yarn.lock", manager: .yarn, dependency: dep,
                vulnerability: vuln, fixedVersion: fixed, requiredBy: manifest.requiredBy["proxy-addr"] ?? [], lockedVersions: ["2.0.7"])
            return VulnerablePackage(project: dir, projectName: "movies", file: "yarn.lock", manager: .yarn, dependency: dep, findings: [finding])
        }

        // 2.0.8 entre dans ~2.0.7 : mais « yarn upgrade proxy-addr » ne fait rien pour un sous-paquet (yarn 1).
        // On retire son entrée du yarn.lock, puis « yarn install » la re-résout.
        let free = package(fixed: "2.0.8")
        #expect(free.blockers.isEmpty)
        #expect(DependencyFix.fix(free) == nil)
        #expect(DependencyFix.canRelock(free))
        let relock = try #require(DependencyFix.fixPlan([free]))
        guard relock.steps.count == 2, case .editFile(let lockEdit) = relock.steps[0], case .command(let reinstall) = relock.steps[1] else {
            Issue.record("étapes inattendues : \(relock.steps)")
            return
        }
        #expect(lockEdit.file.lastPathComponent == "yarn.lock")
        #expect(lockEdit.removed == ["proxy-addr@~2.0.7"])
        #expect(!lockEdit.after.contains("proxy-addr@"))
        #expect(lockEdit.after.contains("proxy-addr \"~2.0.7\""))
        #expect(lockEdit.after.contains("qs@6.13.0:"))
        #expect(reinstall.arguments == ["install"])
        #expect(relock.purpose == .dependencyFix([DependencyExpectation(project: dir, file: "yarn.lock", name: "proxy-addr", vulnerableVersion: "2.0.7")]))

        // 2.1.0 en sort : plus de « yarn upgrade » qui ne ferait rien, on force la version.
        let blocked = package(fixed: "2.1.0")
        #expect(blocked.blockers.map(\.parent) == ["express"])
        #expect(DependencyFix.fix(blocked) == nil)
        #expect(DependencyFix.canForce(blocked))
        let plan = try #require(DependencyFix.fixPlan([blocked]))
        #expect(plan.title.contains("proxy-addr"))
        #expect(plan.summary.contains("express 4.21.2 (~2.0.7)"))
        guard plan.steps.count == 2, case .editFile(let edit) = plan.steps[0], case .command(let install) = plan.steps[1] else {
            Issue.record("étapes inattendues : \(plan.steps)")
            return
        }
        #expect(edit.after.contains("\"resolutions\": {\n    \"proxy-addr\": \"^2.1.0\"\n  }"))
        #expect(install.arguments == ["install"])

        // Autre exemplaire du paquet dans une autre série : on ne force pas, on explique.
        var mixed = blocked
        mixed.findings[0].lockedVersions = ["2.0.7", "1.0.0"]
        #expect(!DependencyFix.canForce(mixed))
        #expect(DependencyFix.blockedReason(mixed)?.contains("express") == true)
        #expect(DependencyFix.fixPlan([mixed]) == nil)
    }

    /// La commande réussit, mais le lockfile n'a pas bougé : l'historique ne doit pas afficher ✓.
    @Test func unchangedLockfileIsReported() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{\n  \"dependencies\": {\n    \"express\": \"^4.21.0\"\n  }\n}\n"
            .write(to: dir.appending(path: "package.json"), atomically: true, encoding: .utf8)
        try Self.yarnClassic.write(to: dir.appending(path: "yarn.lock"), atomically: true, encoding: .utf8)

        let expected = [
            DependencyExpectation(project: dir, file: "yarn.lock", name: "proxy-addr", vulnerableVersion: "2.0.7"),
            DependencyExpectation(project: dir, file: "yarn.lock", name: "qs", vulnerableVersion: "6.12.0"),
        ]
        #expect(DependencyExpectation.unchanged(expected).map(\.name) == ["proxy-addr"])

        var plan = ActionPlan(title: "t", summary: "", kind: .paquet, risk: .caution, reversible: true,
                              steps: [.command(CommandSpec("/usr/bin/true", []))], stopOnFailure: false)
        plan.purpose = .dependencyFix(Array(expected.prefix(1)))
        let entry = await PlanExecutor(runner: CommandRunner()).execute(plan)
        guard case .failure(let message) = entry.outcome else {
            Issue.record("attendu : échec, obtenu \(entry.outcome)")
            return
        }
        #expect(message.contains("proxy-addr 2.0.7"))

        plan.purpose = .dependencyFix(expected)
        let partial = await PlanExecutor(runner: CommandRunner()).execute(plan)
        guard case .partial = partial.outcome else {
            Issue.record("attendu : partiel, obtenu \(partial.outcome)")
            return
        }
    }

    @Test func yarnLockRemovalKeepsOtherEntries() {
        let lock = """
        lodash@^4.17.0, lodash@^4.17.21:
          version "4.17.21"

        lodash@^3.0.0:
          version "3.10.1"

        lodash.merge@^4.6.2:
          version "4.6.2"

        """
        let result = YarnLock.removing("lodash", version: "4.17.21", from: lock)
        #expect(result?.removed == ["lodash@^4.17.0, lodash@^4.17.21"])
        #expect(result?.text == "lodash@^3.0.0:\n  version \"3.10.1\"\n\nlodash.merge@^4.6.2:\n  version \"4.6.2\"\n")
        #expect(YarnLock.removing("lodash", version: "9.9.9", from: lock) == nil)
    }
}
