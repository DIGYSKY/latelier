import Foundation
import Testing
@testable import LAtelierCore

private func tempHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("latelier-storage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

private func write(_ home: URL, _ relative: String, bytes: Int = 2_000_000) throws {
    let url = home.appending(path: relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: bytes).write(to: url)
}

@Suite struct PackageCacheTests {
    @Test func groups() async throws {
        let home = try tempHome()
        try write(home, ".npm/_cacache/content/a")
        try write(home, ".cache/pip/http/b")
        try write(home, ".cache/mystery-tool/c")
        try write(home, ".cache/p10k-dump/d")
        try write(home, ".rustup/toolchains/stable/e")
        try write(home, ".m2/repository/org/f")
        try write(home, "Library/Developer/Xcode/DerivedData/App-abc/g")
        let runner = CommandRunner(locator: ToolLocator(searchPaths: []))
        let groups = await PackageCacheScanner(home: home, runner: runner).scan()
        let ids = groups.map(\.id)
        #expect(ids == ["managers", "xcode", "dotcache", "toolchains"])

        let managers = groups[0].items
        // npm introuvable : la ligne est verrouillée (on ne supprime pas le cache à la main).
        let npm = try #require(managers.first { $0.name == "npm" })
        #expect(npm.isLocked)
        let maven = try #require(managers.first { $0.name == "Maven" })
        #expect(!maven.selectedByDefault && maven.risk == .caution && maven.action == .remove)

        let derived = try #require(groups[1].items.first)
        #expect(derived.name == "DerivedData" && derived.meta == "1 projet" && derived.selectedByDefault)

        let dot = groups[2].items
        #expect(dot.first { $0.name == "pip" }?.selectedByDefault == true)
        #expect(dot.first { $0.name == "mystery-tool" }?.selectedByDefault == false)
        #expect(!dot.contains { $0.name.hasPrefix("p10k") })
        #expect(groups[3].items.allSatisfy { $0.isLocked })
    }

    @Test func commandsInPlan() throws {
        let item = CleanupItem(id: "x", name: "npm", detail: "", entries: [CleanupItem.Entry(url: URL(fileURLWithPath: "/tmp/x"), bytes: 10)],
                               action: .commands([CommandSpec("/usr/bin/npm", ["cache", "clean", "--force"])]))
        let plan = try #require(CleanupPlanner.plan(title: "Caches", items: [item]))
        #expect(plan.commands.count == 1)
        #expect(!plan.removesFiles)
        #expect(!plan.reversible)
        #expect(plan.estimatedBytes == 10)
    }
}

@Suite struct DockerTests {
    static let json = """
    {"Images":[{"Containers":"1","Repository":"mysql","Tag":"8.4","Size":"1.11GB","UniqueSize":"1.112GB"},
               {"Containers":"0","Repository":"node","Tag":"18","Size":"1GB","UniqueSize":"900MB"},
               {"Containers":"0","Repository":"<none>","Tag":"<none>","UniqueSize":"10MB"}],
     "Containers":[{"Names":"db-1","Image":"mysql:8.4","State":"running","Status":"Up","Size":"32.8kB (virtual 864MB)","Labels":"com.docker.compose.project=bank"},
                   {"Names":"old-1","Image":"node:18","State":"exited","Status":"Exited (0) 3 weeks ago","Size":"1.5MB"}],
     "Volumes":[{"Name":"amiral-api_postgres-data","Size":"48.33MB","Links":"0","Labels":"com.docker.compose.project=amiral-api,com.docker.compose.volume=postgres-data"},
                {"Name":"amiral-web_node_modules","Size":"305MB","Links":"0","Labels":"com.docker.compose.volume=node_modules"},
                {"Name":"amiral-api_maven-cache","Size":"187.3MB","Links":"0","Labels":"com.docker.compose.volume=maven-cache"},
                {"Name":"shared","Size":"1MB","Links":"0","Labels":""},
                {"Name":"live_db","Size":"2GB","Links":"1","Labels":""}],
     "BuildCache":[{"Size":"1.3GB","InUse":"false"},{"Size":"5GB","InUse":"true"}]}
    """

    @Test func sizes() {
        #expect(DockerScanner.bytes("1.112GB") == 1_112_000_000)
        #expect(DockerScanner.bytes("32.77kB") == 32_770)
        #expect(DockerScanner.bytes("0B") == 0)
    }

    @Test func parseAndGroups() throws {
        let report = try #require(DockerScanner.parse(Data(Self.json.utf8)))
        #expect(report.images.count == 3)
        #expect(report.containers.filter { $0.running }.count == 1)
        #expect(report.buildCache == 1_300_000_000)
        #expect(report.volumes.first?.composeName == "postgres-data")

        let groups = DockerScanner.groups(report, docker: "/usr/local/bin/docker")
        #expect(groups.map(\.id) == ["docker-safe", "docker-review", "docker-data"])
        let safe = groups[0].items
        let images = try #require(safe.first { $0.id == "docker:images" })
        #expect(images.bytes == 910_000_000)
        #expect(images.action == .commands([CommandSpec("/usr/local/bin/docker", ["image", "prune", "-a", "-f"])]))
        #expect(safe.contains { $0.name == "amiral-web_node_modules" && $0.selectedByDefault })
        #expect(safe.contains { $0.name == "amiral-api_maven-cache" && $0.selectedByDefault })
        #expect(safe.first { $0.name == "live_db" }?.isLocked == true)
        #expect(safe.first { $0.name.hasPrefix("db-1") }?.isLocked == true)
        #expect(groups[1].items.map(\.name) == ["shared"])
        let data = try #require(groups[2].items.first)
        #expect(data.name == "amiral-api_postgres-data" && !data.selectedByDefault && data.risk == .danger)
    }

    @Test func notRunning() {
        #expect(DockerScanner.groups(DockerReport(state: .notInstalled), docker: "docker").isEmpty)
    }
}

@Suite struct ApplicationsTests {
    @Test func bundleIDs() {
        #expect(LeftoverScanner.looksLikeBundleID("com.todesktop.230313mzl4w4u92"))
        #expect(LeftoverScanner.looksLikeBundleID("us.zoom.xos"))
        #expect(LeftoverScanner.looksLikeBundleID("notion.id"))
        #expect(!LeftoverScanner.looksLikeBundleID("Google"))
        #expect(!LeftoverScanner.looksLikeBundleID("default.store"))
        #expect(!LeftoverScanner.looksLikeBundleID("BLOB-E Demo.settings"))
        #expect(LeftoverScanner.readableName("com.todesktop.230313mzl4w4u92") == "Cursor")
        #expect(LeftoverScanner.readableName("com.example.superApp.mac") == "SuperApp")
    }

    @Test func leftovers() throws {
        let home = try tempHome()
        try write(home, "Library/Application Support/com.todesktop.230313mzl4w4u92/state.db")
        try write(home, "Library/Caches/com.todesktop.230313mzl4w4u92/blob")
        try write(home, "Library/Preferences/us.zoom.xos.plist", bytes: 10_000)
        try write(home, "Library/Application Support/com.google.Keystone/x")
        try write(home, "Library/Application Support/com.apple.something/x")
        try write(home, "Library/Application Support/Code/User/settings.json")
        try write(home, "Library/Application Support/com.running.app/x")
        let scanner = LeftoverScanner(home: home, installedIDs: ["com.google.chrome"], runningIDs: ["com.running.app"])
        let found = scanner.scan()
        let ids = Set(found.map { $0.id })
        #expect(ids == ["com.todesktop.230313mzl4w4u92", "us.zoom.xos", "com.microsoft.vscode"])
        let cursor = try #require(found.first { $0.id.hasPrefix("com.todesktop") })
        #expect(cursor.name == "Cursor")
        #expect(cursor.folders.sorted() == ["Application Support", "Caches"])

        // Modifié à l'instant : à vérifier, pas coché.
        var sizes: [URL: Int64] = [:]
        for url in found.flatMap(\.urls) { sizes[url] = DiskUsage.measure(url).bytes }
        let items = scanner.items(found, sizes: sizes)
        #expect(items.allSatisfy { !$0.selectedByDefault && $0.risk == .caution } && items.count == 1)
        let later = LeftoverScanner(home: home, installedIDs: [], now: Date().addingTimeInterval(200 * 86_400))
        #expect(later.items(found, sizes: sizes).allSatisfy { $0.selectedByDefault })
    }

    @Test func parts() throws {
        let home = try tempHome()
        try write(home, "Library/Application Support/com.postmanlabs.mac/a")
        try write(home, "Library/Application Support/Postman/b")
        try write(home, "Library/Caches/com.postmanlabs.mac/c")
        try write(home, "Library/Preferences/com.postmanlabs.mac.plist", bytes: 100)
        try write(home, "Library/Preferences/ByHost/com.postmanlabs.mac.ABCD.plist", bytes: 100)
        try write(home, "Library/LaunchAgents/com.postmanlabs.mac.updater.plist", bytes: 100)
        let parts = AppInventory.parts(bundleID: "com.postmanlabs.mac", name: "Postman", home: home)
        #expect(parts.count == 6)
        #expect(parts.filter { $0.isPreference }.count == 2)
        #expect(parts.contains { $0.kind == "Agent de démarrage" })
        // Nom trop général : pas de rapprochement.
        try write(home, "Library/Application Support/Google/x")
        #expect(AppInventory.parts(bundleID: nil, name: "Google", home: home).isEmpty)
    }

    @Test func uninstall() {
        let app = InstalledApp(url: URL(fileURLWithPath: "/Applications/Postman.app"), name: "Postman", bundleID: "com.postmanlabs.mac",
                               version: "11", lastUsed: nil, fromAppStore: false, isSystem: false, deletable: true, bytes: 500)
        let part = AppInventory.Part(url: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/com.postmanlabs.mac"),
                                     kind: "Cache", isPreference: false, isContainer: false)
        let target = ProcessTarget(pid: 42, name: "Postman", started: 1, isApp: true)
        let plan = AppInventory.uninstallPlan(app: app, parts: [(part, 100)], running: target, brew: nil)
        #expect(plan.steps.count == 3)
        #expect(plan.steps[0] == .signal(target, force: false))
        #expect(plan.steps[1] == .remove(app.url, bytes: 500, permanently: false))
        #expect(plan.estimatedBytes == 600)
        #expect(plan.reversible)

        let brew = AppInventory.uninstallPlan(app: app, parts: [], running: nil, brew: ("/opt/homebrew/bin/brew", "postman"))
        #expect(brew.commands.first?.arguments == ["uninstall", "--cask", "postman"])
        #expect(!brew.reversible)

        var store = app
        store.deletable = false
        let finder = AppInventory.uninstallPlan(app: store, parts: [], running: nil, brew: nil)
        #expect(finder.commands.first?.arguments.last?.contains("tell application \"Finder\" to delete (POSIX file \"/Applications/Postman.app\" as alias)") == true)
    }

    @Test func safetyAllowsOnlyApps() throws {
        let guardian = SafetyGuard.standard
        try guardian.check(URL(fileURLWithPath: "/Applications/Postman.app"))
        #expect(throws: SafetyGuard.Refusal.self) { try guardian.check(URL(fileURLWithPath: "/Applications/Utilities/Terminal.app")) }
        #expect(throws: SafetyGuard.Refusal.self) { try guardian.check(URL(fileURLWithPath: "/Applications")) }
        #expect(throws: SafetyGuard.Refusal.self) { try guardian.check(URL(fileURLWithPath: "/Applications/notes.txt")) }
        #expect(throws: SafetyGuard.Refusal.self) { try guardian.check(URL(fileURLWithPath: "/System/Applications/Mail.app")) }
    }

    @Test func deadLinks() throws {
        let dir = try tempHome()
        try FileManager.default.createSymbolicLink(atPath: dir.appending(path: "code").path,
                                                   withDestinationPath: "/Applications/Nope Code.app/Contents/Resources/app/bin/code")
        try FileManager.default.createSymbolicLink(atPath: dir.appending(path: "ok").path, withDestinationPath: "/bin/ls")
        let links = DeadLinks.find(in: dir)
        #expect(links.map(\.url.lastPathComponent) == ["code"])
        #expect(DeadLinks.appName(links[0]) == "Nope Code.app")
        // Hors de /usr/local/bin : aucune commande admin.
        #expect(DeadLinks.removalCommand(links) == nil)
        let usr = DeadLinks.Link(url: URL(fileURLWithPath: "/usr/local/bin/code"), destination: "/Applications/X.app/code")
        let command = try #require(DeadLinks.removalCommand([usr]))
        #expect(command.arguments.last == "do shell script \"/bin/rm -f '/usr/local/bin/code'\" with administrator privileges")
    }
}

@Suite struct DiskMapTests {
    @Test func treemap() {
        let rects = Treemap.layout([50, 30, 20, 0], width: 100, height: 50)
        #expect(rects.count == 3)
        let area = rects.reduce(0) { $0 + $1.width * $1.height }
        #expect(abs(area - 5000) < 0.001)
        #expect(abs(rects[0].width * rects[0].height - 2500) < 0.001)
        #expect(rects.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x + $0.width <= 100.0001 && $0.y + $0.height <= 50.0001 })
    }

    @Test func descriptions() {
        let home = "/Users/test"
        #expect(FolderExplorer.describe(URL(fileURLWithPath: "/Users/test/Library/Caches"), home: home).0 == .safe)
        #expect(FolderExplorer.describe(URL(fileURLWithPath: "/Users/test/Movies"), home: home).0 == .personal)
        #expect(FolderExplorer.describe(URL(fileURLWithPath: "/Users/test/.rustup"), home: home).0 == .protected)
        let projects = URL(fileURLWithPath: "/Users/test/projects")
        #expect(FolderExplorer.describe(projects, home: home, projectRoots: [projects]).2 == "dev")
        #expect(FolderExplorer.describe(URL(fileURLWithPath: "/Users/test/projects/x/node_modules"), home: home).0 == .safe)
    }

    @Test func explorerSkipsPrivateFolders() async throws {
        let home = try tempHome()
        try write(home, "Movies/a.mov")
        try write(home, "Documents/secret.pdf")
        let nodes = await FolderExplorer.children(of: home, allowPersonal: false, home: home.path)
        let documents = try #require(nodes.first { $0.name == "Documents" })
        #expect(documents.needsPermission && documents.bytes == nil)
        #expect(nodes.first { $0.name == "Movies" }?.bytes ?? 0 >= 2_000_000)
        let allowed = await FolderExplorer.children(of: home, allowPersonal: true, home: home.path)
        #expect(allowed.first { $0.name == "Documents" }?.bytes ?? 0 >= 2_000_000)
    }

    @Test func privacy() {
        let skipped = PrivacyZones.skipped(allowPersonal: false, home: "/Users/t")
        #expect(skipped.contains("/Users/t/Downloads"))
        #expect(skipped.contains("/Users/t/Library/Containers"))
        #expect(!PrivacyZones.skipped(allowPersonal: true, home: "/Users/t").contains("/Users/t/Downloads"))
    }
}

@Suite struct SonarTests {
    @Test func scanDuplicatesAndInstallers() async throws {
        let home = try tempHome()
        try write(home, "Movies/Vacances.mov", bytes: 3_000_000)
        try write(home, "Movies/Copie/Vacances copie.mov", bytes: 3_000_000)
        try write(home, "Movies/autre.mp4", bytes: 3_000_001)
        try write(home, "Movies/petit.mov", bytes: 10_000)
        try write(home, "Downloads/Docker.dmg", bytes: 3_000_002)
        try write(home, "Movies/projet/.git/HEAD", bytes: 10)
        try write(home, "Movies/projet/gros.mov", bytes: 5_000_000)
        let scanner = SonarScanner(home: home, allowPersonal: false, minimumBytes: 1_000_000, installedApps: ["docker"])
        let files = await scanner.scan(.home)
        // Téléchargements non autorisés ; le projet git est ignoré ; le petit fichier aussi.
        #expect(Set(files.map(\.name)) == ["Vacances.mov", "Vacances copie.mov", "autre.mp4"])
        #expect(files.filter { $0.duplicateOf != nil }.count == 1)
        #expect(files.allSatisfy { $0.kind == .video })

        let all = await SonarScanner(home: home, allowPersonal: true, minimumBytes: 1_000_000, installedApps: ["docker"]).scan(.downloads)
        let dmg = try #require(all.first)
        #expect(dmg.kind == .installer && dmg.installedApp == "Docker" && dmg.zone == .downloads)
        #expect(dmg.reason().contains("Docker est installée"))
    }

    @Test func reasonsAndLenses() {
        let now = Date()
        var file = SonarFile(url: URL(fileURLWithPath: "/x/old.zip"), bytes: 2_000_000_000, kind: .archive, lastUsed: nil,
                             created: now.addingTimeInterval(-400 * 86_400), modified: nil, zone: .downloads)
        #expect(file.reason(now: now) == "Téléchargé il y a 1,1 an et jamais ouvert.")
        #expect(SonarLens.old.matches(file, now: now) && SonarLens.big.matches(file, now: now) && SonarLens.downloads.matches(file, now: now))
        #expect(!SonarLens.duplicates.matches(file, now: now))
        file.lastUsed = now.addingTimeInterval(-3 * 86_400)
        #expect(file.reason(now: now) == "Ouvert récemment : sans doute encore utile.")
        #expect(SonarRadar.radius(ageDays: 3) < SonarRadar.radius(ageDays: 400))
        #expect(SonarRadar.radius(ageDays: 5000) <= 0.94)
    }
}

/// Lecture seule sur la vraie machine : LATELIER_LIVE=1 swift test --filter liveStorage
@Suite struct LiveStorageTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LATELIER_LIVE"] == "1"))
    func liveStorage() async {
        let runner = CommandRunner()
        for group in await PackageCacheScanner(runner: runner).scan() {
            print("CACHE", group.title, group.items.map { "\($0.name)=\($0.bytes / 1_000_000)Mo\($0.selectedByDefault ? "✓" : "")\($0.isLocked ? "🔒" : "")" })
        }
        let docker = await DockerScanner.scan(runner: runner)
        for group in DockerScanner.groups(docker, docker: "docker") {
            print("DOCKER", group.title, group.items.map { "\($0.name)=\($0.bytes / 1_000_000)Mo\($0.selectedByDefault ? "✓" : "")" })
        }
        let ids = AppInventory.allBundleIDs()
        let scanner = LeftoverScanner(installedIDs: ids)
        let leftovers = scanner.scan()
        var sizes: [URL: Int64] = [:]
        for url in leftovers.flatMap(\.urls) { sizes[url] = DiskUsage.measure(url).bytes }
        for item in scanner.items(leftovers, sizes: sizes) {
            print("LEFTOVER", item.name, item.bytes / 1_000_000, "Mo", item.detail, item.meta ?? "", item.selectedByDefault ? "✓" : "")
        }
        print("INTERRUPTED", scanner.interruptedInstalls().map(\.path))
        print("DEADLINKS", DeadLinks.find().map { "\($0.url.lastPathComponent) → \($0.destination)" })
        let apps = AppInventory.installed()
        print("APPS", apps.count, apps.map { "\($0.name)\($0.deletable ? "" : "(root)")\($0.fromAppStore ? "(MAS)" : "") \($0.lastUsed.map { RelativeDate.french($0) } ?? "-")" })
    }
}

@Suite struct CoverageMissingTests {
    @Test func vitestWithoutProvider() throws {
        let project = try tempHome()
        try #"{"scripts":{"test":"vitest"},"devDependencies":{"vitest":"^2.1.8"}}"#.write(to: project.appending(path: "package.json"), atomically: true, encoding: .utf8)
        try "".write(to: project.appending(path: "yarn.lock"), atomically: true, encoding: .utf8)
        let setup = try #require(CoverageDetector.setup(for: project))
        let missing = try #require(setup.missing)
        #expect(missing.package == "@vitest/coverage-v8")
        #expect(missing.install.tool == "yarn")
        #expect(missing.install.arguments == ["add", "--dev", "@vitest/coverage-v8@^2.1.8"])
        let plan = try #require(CoverageDetector.installPlan(project: project, setup: setup, thenRun: true))
        #expect(plan.commands.count == 2)

        // Avec le module de couverture : rien à ajouter.
        try #"{"devDependencies":{"vitest":"^2.1.8","@vitest/coverage-v8":"^2.1.8"}}"#.write(to: project.appending(path: "package.json"), atomically: true, encoding: .utf8)
        #expect(CoverageDetector.setup(for: project)?.missing == nil)
    }

    @Test func pythonWithoutPytestCov() throws {
        let project = try tempHome()
        try "[project]\nname='x'\n[dependency-groups]\ndev=['pytest']\n".write(to: project.appending(path: "pyproject.toml"), atomically: true, encoding: .utf8)
        try "".write(to: project.appending(path: "uv.lock"), atomically: true, encoding: .utf8)
        let setup = try #require(CoverageDetector.setup(for: project))
        #expect(setup.missing?.install.arguments == ["add", "--dev", "pytest-cov"])
    }
}
