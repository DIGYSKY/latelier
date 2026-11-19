import Foundation

/// Trouve les outils en ligne de commande.
///
/// Une app lancée depuis le Finder n'hérite pas du `PATH` du terminal :
/// on ajoute donc les emplacements habituels (Homebrew, cargo, nvm, mise…).
public struct ToolLocator: Sendable {
    public let searchPaths: [String]

    public static let standard = ToolLocator()

    public init(
        searchPaths: [String]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) {
        if let searchPaths {
            self.searchPaths = searchPaths
            return
        }
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let extra = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
            "\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/go/bin", "\(home)/.bun/bin",
            "\(home)/.deno/bin", "\(home)/.volta/bin", "\(home)/.local/share/mise/shims",
            "\(home)/.asdf/shims", "\(home)/.sdkman/candidates/java/current/bin",
            "\(home)/.sdkman/candidates/maven/current/bin",
            "\(home)/.sdkman/candidates/gradle/current/bin",
        ] + Self.latestNvmBin(home: home)
        let system = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

        var seen = Set<String>()
        self.searchPaths = (inherited + extra + system).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Chemin de l'exécutable, ou `nil` s'il n'est pas installé.
    public func locate(_ tool: String) -> URL? {
        let fm = FileManager.default
        if tool.contains("/") {
            return fm.isExecutableFile(atPath: tool) ? URL(fileURLWithPath: tool) : nil
        }
        for directory in searchPaths {
            let path = (directory as NSString).appendingPathComponent(tool)
            if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// Valeur de `PATH` donnée aux processus lancés.
    public var pathVariable: String { searchPaths.joined(separator: ":") }

    private static func latestNvmBin(home: String) -> [String] {
        let root = "\(home)/.nvm/versions/node"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        let latest = versions
            .filter { $0.hasPrefix("v") }
            .max { $0.compare($1, options: .numeric) == .orderedAscending }
        return latest.map { ["\(root)/\($0)/bin"] } ?? []
    }
}
