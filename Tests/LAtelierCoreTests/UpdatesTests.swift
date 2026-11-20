import Foundation
import Testing
@testable import LAtelierCore

@Suite("Mises à jour de L’Atelier")
struct UpdatesTests {
    @Test func comparesVersions() {
        #expect(UpdateChecker.isNewer("0.2.0", than: "0.1.9"))
        #expect(UpdateChecker.isNewer("0.10.0", than: "0.9.2"))
        #expect(UpdateChecker.isNewer("1.0", than: "0.99.99"))
        #expect(!UpdateChecker.isNewer("0.1.0", than: "0.1.0"))
        #expect(!UpdateChecker.isNewer("0.1.0", than: "0.1"))
        #expect(UpdateChecker.isNewer("1.0.0", than: "1.0.0-beta"))
        #expect(!UpdateChecker.isNewer("1.0.0-beta", than: "1.0.0"))
        #expect(UpdateChecker.isNewer("1.0.0-beta.10", than: "1.0.0-beta.9"))
        #expect(UpdateChecker.isNewer("1.0.0-beta.2", than: "1.0.0-beta.1"))
        #expect(!UpdateChecker.isNewer("1.0.0-beta.1", than: "1.0.0-beta.1"))
        #expect(UpdateChecker.isNewer("1.0.0-rc.1", than: "1.0.0-beta.3"))
    }

    @Test func parsesGitHubRelease() throws {
        let json = """
        {"tag_name":"v0.2.0","draft":false,"prerelease":false,"body":"Serveurs SSH",
         "html_url":"https://github.com/o/r/releases/tag/v0.2.0","published_at":"2026-11-20T10:00:00Z",
         "assets":[{"name":"LAtelier-0.2.0.dmg","browser_download_url":"https://github.com/o/r/releases/download/v0.2.0/LAtelier-0.2.0.dmg"},
                   {"name":"LAtelier-0.2.0.dmg.sha256","browser_download_url":"https://github.com/o/r/releases/download/v0.2.0/LAtelier-0.2.0.dmg.sha256"}]}
        """
        let release = try #require(UpdateChecker.parse(Data(json.utf8)))
        #expect(release.version == "0.2.0")
        #expect(release.tag == "v0.2.0")
        #expect(release.dmg?.lastPathComponent == "LAtelier-0.2.0.dmg")
        #expect(release.checksum?.lastPathComponent == "LAtelier-0.2.0.dmg.sha256")
        #expect(release.published != nil)
        #expect(UpdateChecker.parse(Data(#"{"tag_name":"v9","prerelease":true}"#.utf8)) == nil)
    }

    @Test func readsChecksumFile() {
        let hex = String(repeating: "ab", count: 32)
        #expect(UpdateChecker.checksum(in: "\(hex.uppercased())  LAtelier-0.2.0.dmg\n") == hex)
        #expect(UpdateChecker.checksum(in: "rien") == nil)
    }

    @Test func releasePlanVerifiesBeforeReplacing() throws {
        let release = AppRelease(version: "0.2.0", tag: "v0.2.0")
        let installed = URL(fileURLWithPath: "/Applications/L’Atelier.app")
        let steps = try #require(UpdatePlanner.fromRelease(release, dmg: URL(string: "https://example.com/a.dmg")!, sha256: String(repeating: "a", count: 64),
                                                           installed: installed, requirement: "identifier \"io.github.digysky.latelier\"", work: URL(fileURLWithPath: "/tmp/w")))
        let text = steps.map(\.displayString)
        #expect(text[0].hasPrefix("/usr/bin/curl"))
        #expect(text[1].contains("shasum -a 256 -c"))
        #expect(text[2].contains("hdiutil detach"))                     // démontage même si la copie échoue
        #expect(text[3].contains("-R=identifier"))
        #expect(text[3].contains("nouvelle version"))                    // la copie est vérifiée, pas l'image
        #expect(text[4].contains("/bin/mv") && text[4].contains("ancienne version"))  // échange avec retour arrière
        // L'ancienne version ne part à la corbeille qu'à la toute fin.
        if case .remove(let url, _, false) = steps.last! { #expect(url.lastPathComponent == "L’Atelier (ancienne version).app") } else { Issue.record("dernière étape") }
        #expect(SafetyGuard.isApplicationBundle("/Applications/L’Atelier (ancienne version).app"))
    }

    /// Si la nouvelle version ne peut pas prendre la place de l'actuelle, l'actuelle reste où elle était.
    @Test func swapRollsBackOnFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("latelier-swap-\(UUID().uuidString.prefix(6))")
        let installed = root.appendingPathComponent("L’Atelier.app")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let steps = try #require(UpdatePlanner.fromRelease(AppRelease(version: "1.0.0", tag: "v1.0.0"), dmg: URL(string: "https://e.com/a.dmg")!,
                                                           sha256: String(repeating: "a", count: 64), installed: installed, requirement: "x", work: root))
        guard case .command(let swap) = steps[4] else { Issue.record("étape d'échange"); return }
        // Pas de « nouvelle version » préparée : le second mv échoue.
        let result = try await CommandRunner().run(swap)
        #expect(!result.succeeded)
        #expect(FileManager.default.fileExists(atPath: installed.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("L’Atelier (ancienne version).app").path))
    }

    @Test func rejectsSuspiciousVersions() {
        #expect(UpdateChecker.isValidVersion("v1.0.0-beta.2"))
        #expect(!UpdateChecker.isValidVersion("--upload-pack=x"))
        #expect(!UpdateChecker.isValidVersion("1.0/../../x"))
        #expect(UpdateChecker.parse(Data(#"{"tag_name":"-x","assets":[]}"#.utf8)) == nil)
        #expect(UpdatePlanner.fromRelease(AppRelease(version: "../x", tag: "v1"), dmg: URL(string: "https://e.com/a.dmg")!, sha256: String(repeating: "a", count: 64),
                                          installed: URL(fileURLWithPath: "/Applications/A.app"), requirement: "x", work: URL(fileURLWithPath: "/tmp")) == nil)
    }
}

/// De bout en bout (LATELIER_UPDATE_DMG=build/LAtelier-x.dmg) : une « ancienne » app dans un dossier
/// de test est remplacée par celle du .dmg, après empreinte et signature ; l'ancienne va à la corbeille.
@Suite("Mise à jour réelle", .enabled(if: ProcessInfo.processInfo.environment["LATELIER_UPDATE_DMG"] != nil))
struct UpdateLiveTests {
    @Test func installsFromDiskImage() async throws {
        let dmg = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LATELIER_UPDATE_DMG"]!)
        let sha = try #require(UpdateChecker.checksum(in: try String(contentsOf: URL(fileURLWithPath: dmg.path + ".sha256"), encoding: .utf8)))
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".latelier-update-test-\(UUID().uuidString.prefix(6))")
        let installed = root.appendingPathComponent("L’Atelier.app")
        try FileManager.default.createDirectory(at: installed.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try "ancienne".write(to: installed.appendingPathComponent("Contents/marker"), atomically: true, encoding: .utf8)
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let requirement = try #require(ProcessInfo.processInfo.environment["LATELIER_UPDATE_REQUIREMENT"])
        let steps = try #require(UpdatePlanner.fromRelease(AppRelease(version: "9.9.9", tag: "v9.9.9"), dmg: dmg, sha256: sha,
                                                           installed: installed, requirement: requirement, work: work))
        let plan = ActionPlan(title: "test", summary: "", kind: .paquet, risk: .safe, reversible: true, steps: steps)
        let entry = await PlanExecutor().execute(plan)
        for log in entry.commands where log.exitStatus != 0 { print("ÉCHEC \(log.command)\n\(log.output)") }
        #expect(entry.outcome == .success)
        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("Contents/MacOS/LAtelier").path))
        #expect(!FileManager.default.fileExists(atPath: installed.appendingPathComponent("Contents/marker").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("L’Atelier (ancienne version).app").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("L’Atelier (nouvelle version).app").path))
        try? FileManager.default.removeItem(at: root)
    }
}
