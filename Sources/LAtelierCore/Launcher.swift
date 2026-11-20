import AppKit
import Foundation

/// Terminal où ouvrir un projet (réglage).
public enum TerminalApp: String, Sendable, CaseIterable, Codable {
    case terminal, iterm, ghostty, warp

    public var label: String {
        switch self {
        case .terminal: "Terminal"
        case .iterm: "iTerm"
        case .ghostty: "Ghostty"
        case .warp: "Warp"
        }
    }

    public var bundleID: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        case .warp: "dev.warp.Warp-Stable"
        }
    }

    public var installedURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    public static var installed: [TerminalApp] { allCases.filter { $0.installedURL != nil } }
}

/// Éditeurs reconnus, dans l'ordre de préférence par défaut.
public enum EditorApp: String, Sendable, CaseIterable, Codable {
    case vscode, cursor, zed, xcode, sublime, intellij, webstorm, fleet

    public var label: String {
        switch self {
        case .vscode: "VS Code"
        case .cursor: "Cursor"
        case .zed: "Zed"
        case .xcode: "Xcode"
        case .sublime: "Sublime Text"
        case .intellij: "IntelliJ IDEA"
        case .webstorm: "WebStorm"
        case .fleet: "Fleet"
        }
    }

    public var bundleIDs: [String] {
        switch self {
        case .vscode: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        case .zed: ["dev.zed.Zed", "dev.zed.Zed-Preview"]
        case .xcode: ["com.apple.dt.Xcode"]
        case .sublime: ["com.sublimetext.4", "com.sublimetext.3"]
        case .intellij: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]
        case .webstorm: ["com.jetbrains.WebStorm"]
        case .fleet: ["fleet.app"]
        }
    }

    public var installedURL: URL? {
        bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    public static var installed: [EditorApp] { allCases.filter { $0.installedURL != nil } }
}

/// Ouvre un projet dans Claude Code, un terminal, un éditeur ou le Finder.
public enum Launcher {
    public enum Failure: Error, LocalizedError {
        case notInstalled(String)
        case claudeMissing

        public var errorDescription: String? {
            switch self {
            case .notInstalled(let app): "\(app) n’est pas installé."
            case .claudeMissing: "Claude Code (« claude ») est introuvable. Installation : npm install -g @anthropic-ai/claude-code"
            }
        }
    }

    /// Script lancé par le terminal : se place dans le projet, lance la commande, puis laisse un shell ouvert.
    public static func script(directory: URL, command: [String]?, shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") -> String {
        var lines = ["#!\(shell) -l", "cd \(ShellQuote.quote(directory.path)) || exit 1"]
        if let command, !command.isEmpty {
            lines.append("clear")
            lines.append(command.map(ShellQuote.quote).joined(separator: " "))
        }
        lines.append("exec \(ShellQuote.quote(shell)) -l")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Ligne de commande Claude : `claude` ou `claude "<consigne>"`.
    public static func claudeCommand(prompt: String?, locator: ToolLocator = .standard) -> [String] {
        let tool = locator.locate("claude")?.path ?? "claude"
        guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [tool] }
        return [tool, prompt]
    }

    /// Ouvre le terminal dans `directory` et lance `command` (rien pour un simple terminal).
    @MainActor
    public static func openTerminal(_ terminal: TerminalApp, directory: URL, command: [String]?) throws {
        guard let app = terminal.installedURL else { throw Failure.notInstalled(terminal.label) }
        switch terminal {
        case .terminal, .iterm:
            // Un fichier .command est exécuté par Terminal comme par iTerm.
            let url = try writeScript(script(directory: directory, command: command))
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
        case .ghostty:
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            let url = try writeScript(script(directory: directory, command: command))
            configuration.arguments = ["--working-directory=\(directory.path)", "-e", url.path]
            NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        case .warp:
            // Warp n'accepte pas de commande à lancer : on ouvre le dossier et on copie la commande.
            if let command, !command.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command.map(ShellQuote.quote).joined(separator: " "), forType: .string)
            }
            NSWorkspace.shared.open([directory], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @MainActor
    public static func openEditor(_ editor: EditorApp, directory: URL) throws {
        guard let app = editor.installedURL else { throw Failure.notInstalled(editor.label) }
        var target = directory
        // Xcode : le Package.swift ou le projet plutôt que le dossier.
        if editor == .xcode {
            let fm = FileManager.default
            let items = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
            if let workspace = items.first(where: { $0.hasSuffix(".xcworkspace") }) ?? items.first(where: { $0.hasSuffix(".xcodeproj") }) {
                target = directory.appendingPathComponent(workspace)
            } else if items.contains("Package.swift") {
                target = directory.appendingPathComponent("Package.swift")
            }
        }
        NSWorkspace.shared.open([target], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Dossier des scripts de lancement (dans les caches, purgés au fil de l'eau).
    static func writeScript(_ text: String) throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.latelier/launch", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // On garde les 20 derniers.
        if let old = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for url in old.sorted(by: { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
                > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }).dropFirst(20) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let url = dir.appendingPathComponent("latelier-\(UUID().uuidString.prefix(8)).command")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

/// Consignes « Corriger avec Claude » prêtes à l'emploi.
public enum ClaudePrompts {
    public static func fixVulnerability(package: String, version: String, fixed: String?, ids: [String], manifest: String) -> String {
        let target = fixed.map { "vers \($0) ou plus" } ?? "vers une version sans faille (aucun correctif publié : propose une alternative)"
        return "Mets à jour \(package) (actuellement \(version)) \(target) pour corriger \(ids.prefix(3).joined(separator: ", "))\(ids.count > 3 ? "…" : ""). "
            + "Le paquet est déclaré dans \(manifest). Lance les tests ensuite et corrige ce qui casse."
    }

    public static func failedCommand(_ command: String, tail: [String]) -> String {
        let output = tail.suffix(15).joined(separator: "\n")
        return "La commande « \(command) » échoue. Trouve pourquoi et corrige-la.\n\nFin de la sortie :\n\(output)"
    }

    public static func suggestion(title: String, why: String) -> String {
        "\(title) : \(why) Fais la modification et vérifie qu’elle fonctionne."
    }

    public static func coverage(weakest: [FileCoverage], threshold: Int) -> String {
        let files = weakest.prefix(4).map { "\($0.path) (\(Int($0.percent)) %)" }.joined(separator: ", ")
        return "Ajoute des tests pour améliorer la couverture (objectif \(threshold) %). Fichiers les moins couverts : \(files). Ne modifie pas le comportement du code."
    }

    public static func align(library: String, version: String) -> String {
        "Mets à jour \(library) vers \(version) et corrige ce qui casse (changements incompatibles, types, tests)."
    }
}
