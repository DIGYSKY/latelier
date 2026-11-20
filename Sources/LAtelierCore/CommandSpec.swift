import Foundation

/// Une commande externe à lancer (git, brew, docker…), décrite sans shell :
/// les arguments sont passés tels quels, rien n'est interprété.
public struct CommandSpec: Sendable, Hashable, Codable {
    /// Nom de l'outil (`git`) ou chemin absolu (`/usr/bin/git`).
    public var tool: String
    public var arguments: [String]
    public var workingDirectory: URL?
    /// Variables ajoutées à l'environnement hérité.
    public var environment: [String: String]

    public init(
        _ tool: String,
        _ arguments: [String] = [],
        in workingDirectory: URL? = nil,
        environment: [String: String] = [:]
    ) {
        self.tool = tool
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    /// Forme lisible, copiable dans un terminal. Sert à l'aperçu et à l'historique.
    public var displayString: String {
        let command = ([tool] + arguments).map(ShellQuote.quote).joined(separator: " ")
        guard let workingDirectory else { return command }
        return String(localized: "cd \(ShellQuote.quote(workingDirectory.path)) && \(command)")
    }
}

public enum ShellQuote {
    private static let safe = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@%+,"
    )

    /// Entoure de guillemets simples seulement si nécessaire.
    public static func quote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        if value.unicodeScalars.allSatisfy(safe.contains) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
