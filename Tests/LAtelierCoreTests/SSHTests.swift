import Foundation
import Testing
@testable import LAtelierCore

@Suite("SSH : ~/.ssh/config")
struct SSHConfigTests {
    let sample = """
    # Réglages communs
    Host *
        ServerAliveInterval 30

    # Serveur de prod
    Host prod web
        HostName 203.0.113.10
        User deploy
        Port 2222
        IdentityFile ~/.ssh/id_prod
        ForwardAgent yes

    Host perso
      HostName exemple.fr
      # clé par défaut
      User=moi

    Match host *.interne
        User admin
    """

    @Test func readsHostsAndSkipsWildcards() {
        let config = SSHConfig(text: sample)
        let hosts = config.hosts
        #expect(hosts.map { $0.alias } == ["prod", "perso"])
        let prod = hosts[0]
        #expect(prod.otherAliases == ["web"])
        #expect(prod.hostName == "203.0.113.10")
        #expect(prod.user == "deploy")
        #expect(prod.port == 2222)
        #expect(prod.identityFile == "~/.ssh/id_prod")
        #expect(prod.extra == [SSHOption("ForwardAgent", "yes")])
        #expect(prod.note == "Serveur de prod")
        #expect(prod.destination == "deploy@203.0.113.10:2222")
        #expect(hosts[1].user == "moi")
        #expect(config.wildcardPatterns == ["*"])
    }

    @Test func replacingKeepsEverythingElse() throws {
        let config = SSHConfig(text: sample)
        var perso = config.hosts[1]
        perso.port = 2200
        let text = try #require(config.replacing("perso", with: perso))
        #expect(text.contains("Host *\n    ServerAliveInterval 30"))
        #expect(text.contains("Host prod web"))
        #expect(text.contains("Host perso\n  # clé par défaut\n  HostName exemple.fr\n  User moi\n  Port 2200"))
        #expect(text.contains("Match host *.interne"))
        let again = SSHConfig(text: text)
        #expect(again.hosts.map { $0.alias } == ["prod", "perso"])
        #expect(again.hosts[1].port == 2200)
    }

    @Test func addingAndRemoving() throws {
        let config = SSHConfig(text: sample)
        let added = config.adding(SSHHost(alias: "nas", hostName: "192.168.1.20", user: "admin"))
        #expect(SSHConfig(text: added).hosts.map { $0.alias } == ["prod", "perso", "nas"])
        let removed = try #require(SSHConfig(text: added).removing("prod"))
        #expect(!removed.contains("Serveur de prod"))
        #expect(!removed.contains("203.0.113.10"))
        #expect(removed.contains("Host *"))
        #expect(SSHConfig(text: removed).hosts.map { $0.alias } == ["perso", "nas"])
        #expect(SSHConfig(text: "").adding(SSHHost(alias: "a", hostName: "b")) == "Host a\n    HostName b\n")
    }

    @Test func validation() {
        let existing = SSHConfig(text: sample).hosts
        #expect(SSHHost(alias: "prod", hostName: "x").problems(existing: existing).count == 1)
        #expect(SSHHost(alias: "prod", hostName: "x").problems(existing: existing, replacing: "prod").isEmpty)
        #expect(!SSHHost(alias: "a b", hostName: "x").problems(existing: []).isEmpty)
        #expect(!SSHHost(alias: "a", hostName: "x", port: 70_000).problems(existing: []).isEmpty)
        #expect(!SSHHost(alias: "a", hostName: "").problems(existing: []).isEmpty)
    }

    @Test func diffLines() {
        let (removed, added) = SSHConfig.diff("Host a\n  Port 22\n", "Host a\n  Port 2222\n")
        #expect(removed == ["  Port 22"])
        #expect(added == ["  Port 2222"])
    }
}

@Suite("SSH : fichiers distants")
struct RemoteListingTests {
    @Test func parsesGNUEpochAndBSD() throws {
        let now = Date(timeIntervalSince1970: 1_763_650_000) // 20 nov. 2025
        let lines = [
            "total 20",
            "drwxr-xr-x  5 deploy deploy 4096 1763600000 .",
            "drwxr-xr-x  3 root   root   4096 1763600000 ..",
            "-rw-r--r--  1 deploy deploy  220 1763600000 mon fichier.txt",
            "lrwxrwxrwx  1 deploy deploy    9 1763600000 current -> releases/3",
            "drwxr-xr-x  2 deploy deploy 4096 Nov 18 10:42 logs",
            "-rw-r--r--  1 deploy deploy 1048576 Jan  3  2024 vieux.tar.gz",
            "crw-rw-rw-  1 root   root   1,   3 Nov 18 10:42 null",
        ]
        let files = RemoteListing.parse(lines, directory: "/srv/app", now: now)
        #expect(files.map { $0.name } == ["mon fichier.txt", "current", "logs", "vieux.tar.gz", "null"])
        #expect(files[0].path == "/srv/app/mon fichier.txt")
        #expect(files[0].size == 220)
        #expect(files[0].modified == Date(timeIntervalSince1970: 1_763_600_000))
        #expect(files[1].kind == .link)
        #expect(files[1].linkTarget == "releases/3")
        #expect(files[2].isDirectory)
        let calendar = Calendar(identifier: .gregorian)
        #expect(calendar.component(.year, from: try #require(files[2].modified)) == 2025)
        #expect(calendar.component(.year, from: try #require(files[3].modified)) == 2024)
        #expect(files[3].size == 1_048_576)
        #expect(files[4].kind == .other)
    }

    @Test func paths() {
        #expect(RemotePath.join("/", "etc") == "/etc")
        #expect(RemotePath.parent("/srv/app") == "/srv")
        #expect(RemotePath.parent("/srv") == "/")
        #expect(RemotePath.crumbs("/srv/app").map { $0.path } == ["/", "/srv", "/srv/app"])
        #expect(!RemotePath.isValidName("a/b"))
        #expect(SSHCommands.scpPath("/a/b*[1].txt") == "/a/b\\*\\[1\\].txt")
    }

    @Test func commandsQuoteRemotePaths() {
        let commands = SSHCommands(alias: "prod", controlDirectory: "/tmp/x")
        let rename = commands.rename("/srv/a b", to: "/srv/c'd")
        #expect(rename.arguments.last!.contains("mv -- '/srv/a b' '/srv/c'\\''d'"))
        #expect(commands.download(["/srv/a b"], to: URL(fileURLWithPath: "/tmp/d")).arguments.suffix(2) == ["prod:/srv/a b", "/tmp/d/"])
        #expect(SSHFailure.explain("deploy@x: Permission denied (publickey).").title == "Accès refusé")
    }
}

/// Sur la vraie machine (LATELIER_LIVE=1) : relire et réécrire chaque bloc de ~/.ssh/config
/// sans rien changer doit redonner les mêmes connexions (rien n'est écrit sur le disque).
@Suite("SSH : ~/.ssh/config réel", .enabled(if: ProcessInfo.processInfo.environment["LATELIER_LIVE"] == "1"))
struct SSHLiveTests {
    @Test func roundTripIsLossless() throws {
        let config = SSHConfig.load()
        for host in config.hosts {
            let text = try #require(config.replacing(host.alias, with: host))
            let again = SSHConfig(text: text)
            #expect(again.hosts == config.hosts.map { var copy = $0; copy.source = again.url; return copy })
            let (removed, added) = SSHConfig.diff(config.text, text)
            print("\(host.alias): −\(removed.count) +\(added.count) \(removed) \(added)")
        }
    }
}

/// Sur un vrai serveur (LATELIER_SSH_LIVE=<alias>) : chaque commande de l'explorateur, dans un dossier
/// de test temporaire, effacé à la fin (corbeille de test comprise).
@Suite("SSH : serveur réel", .enabled(if: ProcessInfo.processInfo.environment["LATELIER_SSH_LIVE"] != nil))
struct SSHServerLiveTests {
    @Test func explorerCommands() async throws {
        let alias = ProcessInfo.processInfo.environment["LATELIER_SSH_LIVE"]!
        SSHCommands.prepareControlDirectory()
        let ssh = SSHCommands(alias: alias)
        let runner = CommandRunner()
        func run(_ spec: CommandSpec) async throws -> CommandResult {
            let result = try await runner.run(spec, timeout: .seconds(60))
            if !result.succeeded { print("ÉCHEC \(spec.displayString)\n\(result.stderr.joined(separator: "\n"))") }
            return result
        }
        let home = try #require(try await run(ssh.home).stdout.first)
        let base = RemotePath.join(home, "latelier test [é] *")
        #expect(try await run(ssh.makeDirectory(base)).succeeded)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("latelier-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let file = local.appendingPathComponent("note d'essai.txt")
        try "bonjour\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(try await run(ssh.upload([file], to: base)).succeeded)
        let listing = RemoteListing.parse(try await run(ssh.list(base)).stdout, directory: base)
        #expect(listing.map { $0.name } == ["note d'essai.txt"])
        #expect(listing.first?.size == 8)
        let renamed = RemotePath.join(base, "renommé.txt")
        #expect(try await run(ssh.rename(RemotePath.join(base, "note d'essai.txt"), to: renamed)).succeeded)
        // Renommer vers un nom pris est refusé.
        #expect(try await run(ssh.makeDirectory(RemotePath.join(base, "pris"))).succeeded)
        #expect(!(try await runner.run(ssh.rename(renamed, to: RemotePath.join(base, "pris")))).succeeded)
        let back = local.appendingPathComponent("retour.txt")
        #expect(try await run(ssh.fetch(renamed, to: back)).succeeded)
        #expect(try String(contentsOf: back, encoding: .utf8) == "bonjour\n")
        try "modifié\n".write(to: back, atomically: true, encoding: .utf8)
        #expect(try await run(ssh.put(back, as: renamed)).succeeded)
        #expect(try await run(ssh.download([renamed], to: local)).succeeded)
        #expect(try String(contentsOf: local.appendingPathComponent("renommé.txt"), encoding: .utf8) == "modifié\n")
        #expect(try await run(ssh.stat(renamed)).stdout.first?.contains("renommé.txt") == true)
        let stamp = "test-\(UUID().uuidString.prefix(8))"
        #expect(try await run(ssh.trash([renamed], stamp: stamp)).succeeded)
        #expect(RemoteListing.parse(try await run(ssh.list(base)).stdout, directory: base).map { $0.name } == ["pris"])
        // Nettoyage : dossier de test et corbeille de test.
        #expect(try await run(ssh.delete([base])).succeeded)
        #expect(try await run(ssh.ssh("rm -rf -- \"$HOME\"/.latelier-corbeille/\(stamp) && rmdir \"$HOME\"/.latelier-corbeille 2>/dev/null; true")).succeeded)
        try? FileManager.default.removeItem(at: local)
    }
}
