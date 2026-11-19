import Foundation
import Testing
@testable import LAtelierCore

@Suite struct DependenciesTests {
    @Test func npmLockV3MarksTopLevelPackages() {
        let lock = """
        {"lockfileVersion": 3, "packages": {
          "": {"dependencies": {"react": "^18.2.0"}},
          "node_modules/react": {"version": "18.2.0", "license": "MIT"},
          "node_modules/loose-envify": {"version": "1.4.0"},
          "node_modules/a/node_modules/react": {"version": "17.0.2"},
          "packages/app": {"version": "1.0.0"},
          "node_modules/app": {"link": true, "resolved": "packages/app"}
        }}
        """
        let deps = NpmLock.parse(Data(lock.utf8))
        #expect(deps.count == 3)
        let merged = DependencyReader.merge(locked: deps, direct: ["react": ("^18.2.0", false)], ecosystem: .npm)
        let direct = merged.filter(\.direct)
        #expect(direct.map(\.version) == ["18.2.0"])
        #expect(direct.first?.license == "MIT")
        #expect(merged.filter { $0.name == "react" }.count == 2)
    }

    @Test func yarnClassicAndBerry() {
        let classic = """
        # yarn lockfile v1

        "@babel/core@^7.0.0", "@babel/core@^7.1.0":
          version "7.2.0"
          resolved "https://registry.yarnpkg.com/@babel/core/-/core-7.2.0.tgz"

        lodash@^4.17.0:
          version "4.17.21"
        """
        #expect(YarnLock.parse(classic).map { "\($0.name)@\($0.version)" } == ["@babel/core@7.2.0", "lodash@4.17.21"])
        let berry = """
        __metadata:
          version: 6

        "next@npm:^13.4.0":
          version: 13.4.2
          resolution: "next@npm:13.4.2"

        "app@workspace:.":
          version: 0.0.0-use.local
        """
        #expect(YarnLock.parse(berry).map { "\($0.name)@\($0.version)" } == ["next@13.4.2"])
    }

    @Test func pnpmVersions() {
        let v9 = """
        lockfileVersion: '9.0'
        importers:
          .:
            dependencies:
              react:
                specifier: ^18
                version: 18.3.1
        packages:
          '@types/node@20.11.0':
            resolution: {integrity: sha512-x}
          react@18.3.1:
            resolution: {integrity: sha512-y}
          react-dom@18.3.1(react@18.3.1):
            resolution: {integrity: sha512-z}
        snapshots:
          react@18.3.1: {}
        """
        #expect(PnpmLock.parse(v9).map { "\($0.name)@\($0.version)" } == ["@types/node@20.11.0", "react@18.3.1", "react-dom@18.3.1"])
        let v6 = """
        packages:
          /axios@1.4.0:
            resolution: {integrity: sha512-a}
            dev: true
          /@scope/pkg/2.0.0:
            resolution: {integrity: sha512-b}
        """
        let deps = PnpmLock.parse(v6)
        #expect(deps.map { "\($0.name)@\($0.version)" } == ["axios@1.4.0", "@scope/pkg@2.0.0"])
        #expect(deps[0].dev)
    }

    @Test func cargoLockAndManifest() {
        let lock = """
        [[package]]
        name = "myapp"
        version = "0.1.0"

        [[package]]
        name = "serde"
        version = "1.0.195"
        source = "registry+https://github.com/rust-lang/crates.io-index"
        """
        #expect(CargoLock.parse(lock).map(\.name) == ["serde"])
        let toml = """
        [package]
        name = "myapp"

        [dependencies]
        serde = { version = "1.0", features = ["derive"] }
        tokio = "1.35"
        local = { path = "../local" }
        rand_core = { package = "rand", version = "0.8" }

        [dev-dependencies]
        insta = "1"

        [dependencies.reqwest]
        version = "0.11"
        """
        let direct = CargoToml.parse(toml)
        #expect(direct["serde"]?.range == "1.0")
        #expect(direct["tokio"]?.range == "1.35")
        #expect(direct["local"] == nil)
        #expect(direct["rand"]?.range == "0.8")
        #expect(direct["insta"]?.dev == true)
        #expect(direct["reqwest"]?.range == "0.11")
    }

    @Test func pythonFiles() {
        let pyproject = """
        [project]
        name = "demo"
        dependencies = [
            "requests>=2.31",
            "Flask_Login[extra]==0.6.3; python_version > '3.8'",
        ]

        [dependency-groups]
        dev = ["pytest>=8"]
        """
        let direct = PyProject.parse(pyproject)
        #expect(direct["requests"]?.range == ">=2.31")
        #expect(direct["flask-login"]?.range == "==0.6.3")
        #expect(direct["pytest"]?.dev == true)
        let reqs = Requirements.parse("# deps\nDjango==4.2.1\nrequests>=2\n-r other.txt\n")
        #expect(reqs.map(\.version) == ["4.2.1", ""])
        let uv = """
        [[package]]
        name = "demo"
        version = "0.1.0"
        source = { editable = "." }

        [[package]]
        name = "Requests"
        version = "2.32.3"
        source = { registry = "https://pypi.org/simple" }
        """
        #expect(TomlLock.parse(uv).map { "\($0.name)@\($0.version)" } == ["requests@2.32.3"])
    }

    @Test func goComposerSwiftMavenRuby() {
        let mod = """
        module example.com/app

        go 1.22

        require github.com/spf13/cobra v1.8.0
        require (
            golang.org/x/text v0.14.0 // indirect
        )
        """
        let go = GoMod.parse(mod)
        #expect(go.map(\.direct) == [true, false])
        let composer = Composer.parseLock(Data(#"{"packages":[{"name":"symfony/http-kernel","version":"v6.4.1","license":["MIT"]}],"packages-dev":[]}"#.utf8))
        #expect(composer.first?.version == "6.4.1")
        #expect(SwiftPackage.identity("https://github.com/apple/swift-nio.git") == "github.com/apple/swift-nio")
        let pom = """
        <project><version>1.0</version><properties><jackson.version>2.15.2</jackson.version></properties>
        <dependencies><dependency><groupId>com.fasterxml.jackson.core</groupId><artifactId>jackson-databind</artifactId>
        <version>${jackson.version}</version></dependency></dependencies></project>
        """
        #expect(Maven.parsePom(pom).first?.version == "2.15.2")
        let gems = """
        GEM
          remote: https://rubygems.org/
          specs:
            nokogiri (1.15.4-arm64-darwin)
            rack (2.2.8)

        DEPENDENCIES
          rack
        """
        let parsed = GemfileLock.parse(gems)
        #expect(parsed.map(\.version) == ["1.15.4", "2.2.8"])
        #expect(parsed.map(\.direct) == [false, true])
    }

    @Test func versionHelpers() {
        #expect(VersionOrder.compare("1.10.0", "1.9.3") == .orderedDescending)
        #expect(VersionOrder.compare("2.0.0-rc.1", "2.0.0") == .orderedAscending)
        #expect(VersionOrder.floor(of: "^18.2.0") == "18.2.0")
        #expect(VersionOrder.floor(of: ">=2.31,<3") == "2.31")
        #expect(VersionOrder.floor(of: "*") == nil)
        #expect(RegistryClient.crateIndexPath("serde") == "se/rd/serde")
        #expect(RegistryClient.crateIndexPath("syn") == "3/s/syn")
        #expect(RegistryClient.goEscape("github.com/BurntSushi/toml") == "github.com/!burnt!sushi/toml")
    }
}

@Suite struct SecurityTests {
    @Test func cvssScores() {
        #expect(CVSS3.baseScore("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H") == 9.8)
        #expect(CVSS3.baseScore("CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:C/C:L/I:L/A:N") == 6.1)
        #expect(CVSS3.baseScore("CVSS:3.1/AV:L/AC:H/PR:H/UI:R/S:U/C:N/I:N/A:L") == 1.8)
    }

    @Test func fixedVersionPicksTheRightRange() throws {
        let json = """
        {"id":"GHSA-test","modified":"2024-01-01T00:00:00Z","summary":"SSRF","aliases":["CVE-2024-1"],
         "database_specific":{"severity":"HIGH"},
         "affected":[{"package":{"ecosystem":"npm","name":"axios"},"ranges":[{"type":"SEMVER","events":[
           {"introduced":"0"},{"fixed":"0.28.0"},{"introduced":"1.0.0"},{"fixed":"1.7.4"}]}]}]}
        """
        let vuln = try #require(Vulnerability.parse(Data(json.utf8)))
        #expect(vuln.severity == .high)
        #expect(vuln.displayID == "CVE-2024-1")
        #expect(vuln.fixedVersion(for: Dependency(ecosystem: .npm, name: "axios", version: "1.4.0")) == "1.7.4")
        #expect(vuln.fixedVersion(for: Dependency(ecosystem: .npm, name: "axios", version: "0.21.1")) == "0.28.0")
    }

    @Test func duplicatesAcrossDatabasesAreMerged() {
        let a = Vulnerability(id: "PYSEC-1", aliases: ["GHSA-x"], summary: "", severity: .unknown, modified: "", affected: [])
        let b = Vulnerability(id: "GHSA-x", aliases: ["PYSEC-1", "CVE-1"], summary: "", severity: .moderate, modified: "", affected: [])
        #expect(Vulnerability.deduplicated([a, b]).map(\.id) == ["GHSA-x"])
    }

    @Test func secretsAreMaskedAndEnvFilesFiltered() {
        let finding = SecretScanner.parseGrep("src/aws.ts:3:const k = \"AKIAIOSFODNN7EXAMPLE\"", repo: URL(fileURLWithPath: "/tmp/r"))
        #expect(finding?.kind == "Clé AWS")
        #expect(finding?.detail == "AKIA••••••••MPLE")
        #expect(finding?.line == 3)
        #expect(SecretScanner.isEnvFile("back/.env"))
        #expect(SecretScanner.isEnvFile(".env.production"))
        #expect(!SecretScanner.isEnvFile(".env.example"))
        #expect(!SecretScanner.isEnvFile("environment.ts"))
        #expect(SecretScanner.sensitiveVariables(in: "DEBUG=true\nAPI_KEY=abcdef123456\nDB_PASSWORD=\n# TOKEN=xyz123456") == ["API_KEY"])
    }

    @Test func fixCommands() {
        let project = URL(fileURLWithPath: "/tmp/p")
        let vuln = Vulnerability(id: "GHSA-a", aliases: [], summary: "", severity: .high, modified: "", affected: [])
        var finding = VulnerabilityFinding(project: project, projectName: "p", file: "yarn.lock", manager: .yarn,
                                           dependency: Dependency(ecosystem: .npm, name: "axios", version: "1.4.0", direct: true),
                                           vulnerability: vuln, fixedVersion: "1.7.4")
        #expect(DependencyFix.fix(finding)?.displayString == "cd /tmp/p && yarn add 'axios@^1.7.4'")
        finding.dependency.direct = false
        finding.manager = .cargo
        #expect(DependencyFix.fix(finding)?.arguments == ["update", "-p", "axios@1.4.0", "--precise", "1.7.4"])
        finding.manager = .pip
        #expect(DependencyFix.fix(finding) == nil)
        #expect(DependencyFix.fix(finding.dependency, to: "1.7.4", manager: .uv, in: project)?.arguments == ["lock", "--upgrade-package", "axios"])
    }

    @Test func appendLineIsIdempotent() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: ".gitignore")
        try "node_modules".write(to: file, atomically: true, encoding: .utf8)
        try PlanExecutor.append("/.env", to: file)
        try PlanExecutor.append("/.env", to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "node_modules\n/.env\n")
    }

    /// Lecture réelle des projets de la machine : `LATELIER_LIVE=1 swift test --filter liveProjects`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LATELIER_LIVE"] != nil))
    func liveProjects() async {
        let projects = RepoScanner(roots: [URL(fileURLWithPath: NSHomeDirectory() + "/projects")]).repositories()
        let clock = ContinuousClock()
        let start = clock.now
        let manifests = projects.flatMap(DependencyReader.read)
        print("Lecture : \(clock.now - start), \(manifests.flatMap(\.dependencies).count) dépendances")
        let osvStart = clock.now
        _ = try? await OSVClient().vulnerabilities(of: manifests.flatMap(\.dependencies))
        print("OSV : \(clock.now - osvStart)")
        let analysis = await ProjectAnalyzer(runner: CommandRunner(), projects: projects).analyze()
        print("Total : \(clock.now - start)")
        for manifest in analysis.manifests {
            print("\(manifest.projectName) · \(manifest.manager.label) · \(manifest.lockfile ?? "sans lockfile") · \(manifest.direct.count) directes / \(manifest.dependencies.count)")
        }
        print("Bibliothèques : \(analysis.libraries.count), obsolètes : \(analysis.libraries.filter { !$0.outdated.isEmpty }.count)")
        print("Failles : \(analysis.vulnerabilities.count)")
        for severity in Severity.allCases.reversed() {
            print("  \(severity.label) : \(analysis.vulnerabilities.filter { $0.severity == severity }.count)")
        }
        for finding in analysis.vulnerabilities.prefix(8) {
            print("  \(finding.severity.label) \(finding.projectName) \(finding.dependency.name)@\(finding.dependency.version) \(finding.vulnerability.id) → \(finding.fixedVersion ?? "—") \(DependencyFix.fix(finding)?.displayString ?? "")")
        }
        for secret in analysis.secrets { print("Secret : \(secret.projectName) \(secret.file):\(secret.line ?? 0) \(secret.kind) \(secret.detail)") }
        for pin in analysis.endOfLife { print("Fin de vie : \(pin.id) \(pin.uses.map(\.project))") }
        print("Sans lockfile : \(analysis.hygiene.withoutLockfile.map(\.project)) ; doublons : \(analysis.hygiene.duplicateLockfiles.map(\.project))")
        print("Problèmes : \(analysis.problems)")
    }
}
