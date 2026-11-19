import Foundation
import Testing
@testable import LAtelierCore

@Suite struct PackagesTests {
    @Test func classifiesUpdateGaps() {
        #expect(UpdateGap.between("3.2.0", "3.4.1") == .minor)
        #expect(UpdateGap.between("8.14.0", "9.0.0") == .major)
        #expect(UpdateGap.between("v1.2.3", "1.2.4") == .patch)
        #expect(UpdateGap.between("0.60.8.2", "0.60.8.3_1") == .patch)
        #expect(UpdateGap.between("1.2.0", "1.2.0_1") == .patch)
        #expect(UpdateGap.between("2026-08-13", "2026-11-05") == .minor)
        #expect(UpdateGap.between("latest", "latest") == .other)
    }

    @Test func readsHomebrewInventory() throws {
        let info = """
        {"formulae":[
          {"name":"aom","desc":"Codec AV1","homepage":"https://aomedia.org","linked_keg":"3.15.1","pinned":false,
           "installed":[{"version":"3.15.0","time":1700000000,"installed_on_request":false},
                        {"version":"3.15.1","time":1710000000,"installed_on_request":false}]},
          {"name":"git","desc":"Contrôle de version","pinned":true,
           "installed":[{"version":"2.43.0","time":1700000000,"installed_on_request":true}]}],
         "casks":[{"token":"ghostty","name":["Ghostty"],"desc":"Terminal","installed":"1.3.1","installed_time":1700000000,
           "artifacts":[{"app":["Ghostty.app"],"target":"/Applications/Ghostty.app"}]}]}
        """
        let outdated = Brew.parseOutdated(Data("""
        {"formulae":[{"name":"aom","installed_versions":["3.15.1"],"current_version":"3.15.3"}],
         "casks":[{"name":"ghostty","installed_versions":["1.3.1"],"current_version":"2.0.0"}]}
        """.utf8))
        let packages = Brew.parseInstalled(Data(info.utf8), outdated: outdated)
        #expect(packages.count == 3)
        let aom = try #require(packages.first { $0.identifier == "aom" })
        #expect(aom.version == "3.15.1")              // la version liée, pas la première
        #expect(aom.latest == "3.15.3")
        #expect(!aom.onRequest)
        #expect(aom.selectedByDefault)
        let git = try #require(packages.first { $0.identifier == "git" })
        #expect(git.pinned && git.latest == nil && !git.selectedByDefault)
        let ghostty = try #require(packages.first { $0.isCask })
        #expect(ghostty.name == "Ghostty")
        #expect(ghostty.appURL?.path == "/Applications/Ghostty.app")
        #expect(ghostty.gap == .major && !ghostty.selectedByDefault)
        #expect(ghostty.upgradeCommand?.arguments == ["upgrade", "--cask", "ghostty"])
    }

    @Test func readsNpmGlobals() throws {
        let box = Sandbox()
        box.file("lib/typescript/package.json")
        try Data(#"{"description":"Compilateur","homepage":"https://typescriptlang.org"}"#.utf8)
            .write(to: box.root.appending(path: "lib/typescript/package.json"))
        let list = #"{"dependencies":{"typescript":{"version":"5.3.3"},"npm":{"version":"11.16.0"}}}"#
        let outdated = #"{"typescript":{"current":"5.3.3","latest":"5.9.2"},"npm":{"current":"11.16.0","latest":"11.16.0"}}"#
        let packages = NpmGlobal.parse(list: Data(list.utf8), outdated: Data(outdated.utf8), root: box.root.appending(path: "lib"))
        #expect(packages.map(\.name) == ["npm", "typescript"])
        #expect(packages[0].latest == nil)
        #expect(packages[0].uninstallCommand != nil && packages[0].lockReason != nil)   // npm : jamais désinstallé
        #expect(packages[1].summary == "Compilateur")
        #expect(packages[1].upgradeCommand?.displayString == "npm install --global typescript@latest")
    }

    @Test func readsCargoMasAndRustup() {
        let crates = CargoInstalled.parse(["ripgrep v14.0.3:", "    rg", "bat v0.24.0 (https://x):", "    bat"])
        #expect(crates.map(\.name) == ["ripgrep", "bat"] && crates[1].version == "0.24.0")

        let apps = MasApps.parse(["1474276998  HP        (26.4.0   -> 26.4.3)", " 497799835  Xcode  (16.0)", "garbage"])
        #expect(apps == [
            MasApps.Entry(id: "1474276998", name: "HP", version: "26.4.0", latest: "26.4.3"),
            MasApps.Entry(id: "497799835", name: "Xcode", version: "16.0", latest: nil),
        ])

        let rust = RustupCheck.parse([
            "stable-aarch64-apple-darwin - update available: 1.94.0 (4a4ef493e 2026-03-02) -> 1.100.0 (0ef1bc386 2026-11-09)",
            "nightly-aarch64-apple-darwin - Up to date : 1.102.0-nightly (abc 2026-11-18)",
            "rustup - Up to date : 1.28.2",
        ])
        #expect(rust.count == 3)
        #expect(rust[0].identifier == "stable" && rust[0].version == "1.94.0" && rust[0].latest == "1.100.0")
        #expect(rust[1].latest == nil)
    }

    @Test func upgradePlanSkipsOpenAppsAndFlagsMajors() throws {
        let open = Package(source: .homebrew, identifier: "ghostty", version: "1.3", latest: "1.4", isCask: true, lockReason: "App ouverte")
        let major = Package(source: .npm, identifier: "pnpm", version: "8.14.0", latest: "9.1.0")
        let minor = Package(source: .homebrew, identifier: "git", version: "2.43.0", latest: "2.47.1")
        let plan = try #require(PackagePlans.upgrade([open, major, minor]))
        #expect(plan.commands.count == 2)
        #expect(plan.skipped == ["ghostty : App ouverte"])
        #expect(plan.risk == .caution && !plan.stopOnFailure && plan.kind == .paquet)
        #expect(PackagePlans.upgrade([open]) == nil)
    }
}

@Suite struct RuntimeTests {
    @Test func resolvesNvmDefaultAlias() throws {
        let box = Sandbox()
        for version in ["v20.19.5", "v22.19.0", "v22.20.0"] { box.dir("versions/node/\(version)") }
        func alias(_ text: String, _ name: String = "default") throws {
            box.file("alias/\(name)")
            try text.write(to: box.root.appending(path: "alias/\(name)"), atomically: true, encoding: .utf8)
        }
        #expect(Nvm.installed(root: box.root) == ["22.20.0", "22.19.0", "20.19.5"])
        try alias("22\n")
        #expect(Nvm.defaultVersion(root: box.root) == "22.20.0")
        try alias("v20.19.5")
        #expect(Nvm.defaultVersion(root: box.root) == "20.19.5")
        try alias("v22.19.0", "lts/jod")
        try alias("lts/jod")
        #expect(Nvm.defaultVersion(root: box.root) == "22.19.0")
        let command = Nvm.command(["uninstall", "20.19.5"], root: box.root)
        #expect(command.tool == "/bin/bash" && command.arguments.suffix(3) == ["nvm", "uninstall", "20.19.5"])
    }

    @Test func matchesProjectPins() throws {
        let box = Sandbox()
        func write(_ path: String, _ text: String) throws {
            box.file(path)
            try text.write(to: box.root.appending(path: path), atomically: true, encoding: .utf8)
        }
        try write("shop/.nvmrc", "v20\n")
        try write("api/.python-version", "3.11")
        try write("indexer/rust-toolchain.toml", "[toolchain]\nchannel = \"stable\"\n")
        try write("svc/go.mod", "module x\n\ngo 1.22\n")
        let pins = ProjectPins.read(["shop", "api", "indexer", "svc"].map { box.root.appending(path: $0) })
        #expect(pins.users(of: "node", version: "20.19.5") == ["shop"])
        #expect(pins.users(of: "node", version: "22.20.0").isEmpty)
        #expect(pins.users(of: "python", version: "3.11.9_1") == ["api"])
        #expect(pins.users(of: "rust", version: "stable 1.94.0") == ["indexer"])
        #expect(pins.users(of: "go", version: "1.22.5") == ["svc"])

        let unused = RuntimeVersion(version: "16.20.2", remove: CommandSpec("x"))
        #expect(unused.canRemove)
        #expect(!RuntimeVersion(version: "20", usedBy: ["shop"], remove: CommandSpec("x")).canRemove)
        #expect(!RuntimeVersion(version: "22", isDefault: true, remove: CommandSpec("x")).canRemove)
    }

    @Test func readsEndOfLifeData() throws {
        let cycles = EndOfLife.parse(Data("""
        [{"cycle":"24","lts":"2025-10-28","eol":"2028-04-30","latest":"24.11.0"},
         {"cycle":"25","lts":false,"eol":"2026-06-01","latest":"25.9.0"},
         {"cycle":"18","lts":"2022-10-25","eol":true}]
        """.utf8))
        #expect(cycles.count == 3)
        #expect(cycles[0].isLTS && !cycles[1].isLTS)
        #expect(cycles[2].eol == .distantPast)
        #expect(EndOfLife.cycle(of: "3.13.15", components: 2) == "3.13")
        #expect(EndOfLife.cycle(of: "22.20.0", components: 1) == "22")
    }
}

@Suite struct ServiceTests {
    @Test func readsBrewServices() {
        let services = BrewServices.parse(Data("""
        [{"name":"postgresql@16","running":true,"registered":true,"pid":812,"exit_code":null,"user":"lilyan",
          "log_path":"/opt/homebrew/var/log/pg.log","error_log_path":"/opt/homebrew/var/log/pg.log"},
         {"name":"nginx","running":false,"registered":false,"pid":null,"exit_code":1,"user":"root"}]
        """.utf8))
        #expect(services.count == 2)
        #expect(services[0].running && services[0].pid == 812)
        #expect(services[1].failed && services[1].runsAsRoot)

        let ports = BrewServices.parsePorts(["p812", "f5", "n*:5432", "n[::1]:5432", "p900", "n127.0.0.1:6379"])
        #expect(ports[812] == [5432] && ports[900] == [6379])

        let plan = BrewServices.stopAll(services)
        #expect(plan?.commands.map(\.displayString) == ["brew services stop postgresql@16"])
        let toggle = BrewServices.toggleAtLogin(services[0])
        #expect(toggle.commands.map { $0.arguments[1] } == ["stop", "run"])
    }
}
