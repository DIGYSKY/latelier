import Foundation

/// Dossiers de travail des processus de l'utilisateur (via `lsof`), pour savoir
/// quels projets sont en cours d'utilisation. Les shells sont ignorés : un terminal
/// ouvert dans un dossier ne « l'utilise » pas.
public struct ProcessDirectories: Sendable {
    public let runner: CommandRunner

    public init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
    }

    private static let shells: Set<String> = ["zsh", "-zsh", "bash", "-bash", "fish", "sh", "login", "tmux", "screen", "nu"]

    public func current() async -> [String] {
        let spec = CommandSpec("/usr/sbin/lsof", ["-a", "-u", String(getuid()), "-d", "cwd", "-F", "cn", "-w"])
        guard let result = try? await runner.run(spec, timeout: .seconds(8)) else { return [] }
        return Self.parse(result.stdout)
    }

    /// Sortie `-F cn` : lignes `p<pid>`, `c<commande>`, `f<fd>`, `n<chemin>`.
    static func parse(_ lines: [String]) -> [String] {
        var command = ""
        var directories: [String] = []
        for line in lines {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": command = ""
            case "c": command = value
            case "n" where !shells.contains(command) && value != "/" && value != NSHomeDirectory():
                directories.append(value)
            default: break
            }
        }
        return Array(Set(directories)).sorted()
    }
}
