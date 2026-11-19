import Foundation

/// Détecte les outils de dev installés et leur version (Réglages › Outils).
public struct ToolProbe: Sendable {
    public struct Tool: Sendable, Hashable, Identifiable {
        public let name: String
        public let versionArguments: [String]
        public var id: String { name }

        public init(_ name: String, _ versionArguments: [String] = ["--version"]) {
            self.name = name
            self.versionArguments = versionArguments
        }
    }

    public struct Status: Sendable, Hashable, Identifiable {
        public let tool: Tool
        public let path: String?
        public let version: String?
        public var id: String { tool.name }
        public var installed: Bool { path != nil }
    }

    public static let defaultTools: [Tool] = [
        Tool("git"), Tool("gh"), Tool("brew"), Tool("docker"),
        Tool("node"), Tool("npm"), Tool("pnpm"), Tool("yarn"), Tool("bun"),
        Tool("python3"), Tool("cargo"), Tool("go", ["version"]),
        Tool("java", ["-version"]), Tool("mvn"), Tool("gradle"),
        Tool("swift"), Tool("claude"),
    ]

    public let runner: CommandRunner

    public init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
    }

    /// Interroge tous les outils en parallèle ; garde l'ordre de la liste.
    public func probe(_ tools: [Tool] = ToolProbe.defaultTools) async -> [Status] {
        await withTaskGroup(of: (Int, Status).self) { group in
            for (index, tool) in tools.enumerated() {
                group.addTask { (index, await probe(tool)) }
            }
            var results = [Status?](repeating: nil, count: tools.count)
            for await (index, status) in group { results[index] = status }
            return results.compactMap { $0 }
        }
    }

    public func probe(_ tool: Tool) async -> Status {
        guard let url = runner.locator.locate(tool.name), await isReal(tool.name, at: url) else {
            return Status(tool: tool, path: nil, version: nil)
        }
        let result = try? await runner.run(
            CommandSpec(url.path, tool.versionArguments), timeout: .seconds(10)
        )
        let version = result.flatMap { Self.firstLine(of: $0.stdout) ?? Self.firstLine(of: $0.stderr) }
        return Status(tool: tool, path: url.path, version: version)
    }

    /// `/usr/bin/java` existe même sans JDK, et l'appeler ouvre une fenêtre
    /// « installer Java » : on vérifie d'abord avec `java_home`.
    private func isReal(_ name: String, at url: URL) async -> Bool {
        guard name == "java", url.path == "/usr/bin/java" else { return true }
        let check = try? await runner.run(CommandSpec("/usr/libexec/java_home"), timeout: .seconds(5))
        return check?.succeeded == true
    }

    static func firstLine(of lines: [String]) -> String? {
        lines.lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
            .map { String($0.prefix(100)) }
    }
}
