import Foundation
import Testing
@testable import LAtelierCore

/// Une machine « vierge » : pas de projets, pas d'outils (ni brew, ni docker, ni git dans le PATH),
/// pas de ~/.ssh/config, dossier personnel vide. Chaque analyse doit rendre un résultat vide, sans planter.
@Suite("Machine vierge")
struct EmptyMachineTests {
    let home: URL
    let noTools = CommandRunner(locator: ToolLocator(searchPaths: []))

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("latelier-vierge-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    @Test func scannersReturnNothing() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(await DevArtifactScanner(roots: [], home: home.path).scan().flatMap(\.items).isEmpty)
        #expect(await DevArtifactScanner(roots: [home.appendingPathComponent("absent")], home: home.path).scan().flatMap(\.items).isEmpty)
        #expect(await RepoScanner(roots: [home]).scan(git: GitClient(runner: noTools)).isEmpty)
        #expect(await PackageCacheScanner(home: home, runner: noTools).scan().flatMap(\.items).isEmpty)
        #expect(LeftoverScanner(home: home, installedIDs: []).scan().isEmpty)
        let sonar = SonarScanner(home: home, allowPersonal: true)
        for zone in SonarZone.allCases { #expect(await sonar.scan(zone).isEmpty) }
        let docker = await DockerScanner.scan(runner: noTools)
        #expect(docker.state == .notInstalled)
    }

    @Test func missingSSHConfigIsEmptyAndCanBeCreated() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent(".ssh/config")
        let config = SSHConfig.load(url)
        #expect(config.hosts.isEmpty && config.allHosts().isEmpty && config.text.isEmpty)
        let after = config.adding(SSHHost(alias: "nas", hostName: "192.168.1.20"))
        // Premier serveur : ~/.ssh et le fichier sont créés, avec des droits stricts.
        try PlanExecutor.write(FileEdit(file: url, before: "", after: after, added: [], backup: true), safety: SafetyGuard(root: home))
        #expect(SSHConfig.load(url).hosts.map { $0.alias } == ["nas"])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test func missingToolsAreReportedNotCrashing() async {
        #expect(noTools.locator.locate("git") == nil)
        await #expect(throws: CommandError.self) { _ = try await noTools.run(CommandSpec("git", ["--version"])) }
    }
}

@Suite("Signaler un problème")
struct IssueReportTests {
    let environment = IssueReport.Environment(appVersion: "1.0.0-beta.1", build: "42", macOS: "26.1.0", architecture: "Apple silicon",
                                              installation: "install.sh", language: "fr")

    @Test func prefillsTheForm() throws {
        let url = try #require(IssueReport.url(repository: "DIGYSKY/latelier", kind: .bug, environment: environment, details: "erreur"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.absoluteString.hasPrefix("https://github.com/DIGYSKY/latelier/issues/new?"))
        #expect(items.first { $0.name == "template" }?.value == "bug_report.yml")
        #expect(items.first { $0.name == "version" }?.value == "1.0.0-beta.1 (42)")
        #expect(items.first { $0.name == "logs" }?.value == "erreur")
        let idea = try #require(IssueReport.url(repository: "DIGYSKY/latelier", kind: .idea, environment: environment))
        #expect(!idea.absoluteString.contains("version="))
        let long = try #require(IssueReport.url(repository: "o/r", kind: .bug, environment: environment, details: String(repeating: "x", count: 20_000)))
        #expect(long.absoluteString.count < 6_000)
    }

    @Test func hidesPersonalPaths() {
        let text = IssueReport.redact("rm: /Users/alice/projects/app: Permission denied (alice)", home: "/Users/alice", user: "alice")
        #expect(text == "rm: ~/projects/app: Permission denied (<utilisateur>)")
    }
}

@Suite("Ancien identifiant")
struct LegacyMigrationTests {
    @Test func copiesSettingsAndMovesData() throws {
        let suite = "latelier-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("dark", forKey: "appearance")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("latelier-mig-\(UUID().uuidString.prefix(6))")
        let old = base.appendingPathComponent(AppPaths.legacyIdentifier)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try "[]".write(to: old.appendingPathComponent("history.json"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: base) }

        let moved = LegacyMigration.run(defaults: defaults, legacyDefaults: ["appearance": "light", "terminal": "iterm"], bases: [base])
        #expect(defaults.string(forKey: "appearance") == "dark")   // un réglage déjà là n'est pas écrasé
        #expect(defaults.string(forKey: "terminal") == "iterm")
        #expect(moved.count == 1)
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent(AppPaths.bundleIdentifier).appendingPathComponent("history.json").path))
        // Une seule fois.
        #expect(LegacyMigration.run(defaults: defaults, legacyDefaults: ["x": 1], bases: [base]).isEmpty)
        #expect(defaults.object(forKey: "x") == nil)
    }
}

@Suite("Pastille de sécurité")
struct SecurityAlertsTests {
    func package(_ project: String, _ severity: Severity) -> VulnerablePackage {
        let url = URL(fileURLWithPath: project)
        let dependency = Dependency(ecosystem: .npm, name: "lodash", version: "4.17.0", direct: true)
        let vulnerability = Vulnerability(id: "GHSA-x", aliases: [], summary: "", severity: severity, modified: "", affected: [])
        return VulnerablePackage(project: url, projectName: project, file: "package.json", manager: nil, dependency: dependency,
                                 findings: [VulnerabilityFinding(project: url, projectName: project, file: "package.json", manager: nil,
                                                                 dependency: dependency, vulnerability: vulnerability, fixedVersion: nil)])
    }

    @Test func countsActiveProjectsWithCriticalFlaws() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let list = [package("/p/actif", .critical), package("/p/actif", .critical), package("/p/vieux", .critical),
                    package("/p/haut", .high), package("/p/inconnu", .critical)]
        let activity: [URL: Date] = [URL(fileURLWithPath: "/p/actif"): now.addingTimeInterval(-86_400),
                                     URL(fileURLWithPath: "/p/vieux"): now.addingTimeInterval(-400 * 86_400),
                                     URL(fileURLWithPath: "/p/haut"): now]
        let result = SecurityAlerts.activeCriticalProjects(list, lastActivity: activity, inactiveAfter: 180 * 86_400, now: now)
        #expect(result.map(\.path) == ["/p/actif", "/p/inconnu"])
    }
}
