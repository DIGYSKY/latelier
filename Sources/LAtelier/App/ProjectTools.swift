import AppKit
import LAtelierCore
import Observation
import SwiftUI

/// Réglages des outils de projet, gardés dans les préférences.
@Observable
final class ToolPreferences {
    private let defaults = UserDefaults.standard

    var terminal: TerminalApp {
        didSet { defaults.set(terminal.rawValue, forKey: "terminal") }
    }
    var editor: EditorApp? {
        didSet { defaults.set(editor?.rawValue, forKey: "editor") }
    }
    var coverageThreshold: Int {
        didSet { defaults.set(coverageThreshold, forKey: "coverageThreshold") }
    }
    var recorderPolicy: RecorderPolicy {
        didSet { defaults.set(recorderPolicy.rawValue, forKey: "recorderPolicy") }
    }
    /// Projets enregistrés sans demander (« Toujours pour ce projet »).
    var alwaysRecord: Set<String> {
        didSet { defaults.set(Array(alwaysRecord), forKey: "alwaysRecord") }
    }
    /// Projets jamais enregistrés.
    var neverRecord: Set<String> {
        didSet { defaults.set(Array(neverRecord), forKey: "neverRecord") }
    }

    init() {
        terminal = TerminalApp(rawValue: defaults.string(forKey: "terminal") ?? "")
            ?? (TerminalApp.iterm.installedURL != nil ? .iterm : .terminal)
        editor = EditorApp(rawValue: defaults.string(forKey: "editor") ?? "") ?? EditorApp.installed.first
        let threshold = defaults.integer(forKey: "coverageThreshold")
        coverageThreshold = threshold == 0 ? 80 : threshold
        recorderPolicy = RecorderPolicy(rawValue: defaults.string(forKey: "recorderPolicy") ?? "") ?? .ask
        alwaysRecord = Set(defaults.stringArray(forKey: "alwaysRecord") ?? [])
        neverRecord = Set(defaults.stringArray(forKey: "neverRecord") ?? [])
    }
}

/// « Ouvrir dans Claude » : la consigne est montrée (et modifiable) avant l'ouverture.
struct ClaudeRequest: Identifiable {
    let id = UUID()
    var project: URL
    var prompt: String
    /// D'où vient la demande (« Faille dans next »), affiché en titre.
    var context: String?
}

extension AppModel {
    func askClaude(_ project: URL, prompt: String = "", context: String? = nil) {
        pendingClaude = ClaudeRequest(project: project, prompt: prompt, context: context)
    }

    func openTerminal(_ project: URL) {
        do {
            try Launcher.openTerminal(preferences.terminal, directory: project, command: nil)
        } catch {
            launchError = error.localizedDescription
        }
    }

    func openEditor(_ project: URL) {
        guard let editor = preferences.editor else {
            NSWorkspace.shared.open(project)
            return
        }
        do {
            try Launcher.openEditor(editor, directory: project)
        } catch {
            launchError = error.localizedDescription
        }
    }

    /// Ouvre Claude Code et note l'ouverture dans l'Historique (sans la consigne complète si elle est longue).
    func launchClaude(_ request: ClaudeRequest) throws {
        let command = Launcher.claudeCommand(prompt: request.prompt, locator: runner.locator)
        if runner.locator.locate("claude") == nil { throw Launcher.Failure.claudeMissing }
        try Launcher.openTerminal(preferences.terminal, directory: request.project, command: command)
        let display = command.enumerated().map { $0.offset == 0 ? "claude" : ShellQuote.quote($0.element) }.joined(separator: " ")
        let entry = HistoryEntry(
            kind: .commande, title: "Claude ouvert dans \(request.project.lastPathComponent)",
            summary: request.context ?? "Session Claude Code dans \(preferences.terminal.label).",
            commands: [CommandLog(command: "cd \(ShellQuote.quote(request.project.path)) && \(display)", exitStatus: 0, output: "", duration: 0)],
            outcome: .success, bytesFreed: nil
        )
        Task { await record(entry) }
    }
}

/// Feuille « Ouvrir dans Claude ».
struct ClaudeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ClaudeRequest
    @ViewState private var prompt = ""
    @ViewState private var error: String?

    var body: some View {
        @Bindable var preferences = model.preferences
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconChip(symbol: "sparkles", color: Color(hex: 0xC96442), size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.context ?? "Ouvrir dans Claude").font(.system(size: 19, weight: .bold))
                    Text("\(request.project.lastPathComponent) · \(request.project.abbreviatingHome())")
                        .font(.system(size: 12).monospaced()).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                }
            }
            Text("Consigne (facultative) : Claude Code démarre dans le dossier du projet avec ce message.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            TextEditor(text: $prompt)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 110, maxHeight: 220)
                .background(Theme.raised.opacity(0.8), in: .rect(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
                .accessibilityLabel("Consigne pour Claude")
            ConsoleBlock(text: "$ cd \(ShellQuote.quote(request.project.path))\n$ " + commandPreview, maxHeight: 120)
            HStack {
                Picker("Terminal", selection: $preferences.terminal) {
                    ForEach(TerminalApp.installed, id: \.self) { Text($0.label).tag($0) }
                }
                .fixedSize()
                if preferences.terminal == .warp {
                    Text("Warp ne lance pas de commande : elle sera copiée, à coller.").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Annuler") { dismiss() }.buttonStyle(.secondary).keyboardShortcut(.cancelAction)
                Button("Ouvrir dans \(preferences.terminal.label)") { open() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Tag.red.0)
            }
            Text("Rien n’est envoyé par L’Atelier : c’est Claude Code, dans votre terminal, qui lit le projet.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .padding(24)
        .frame(width: 600)
        .onAppear { prompt = request.prompt }
    }

    private var commandPreview: String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "claude" : "claude " + ShellQuote.quote(trimmed)
    }

    private func open() {
        var final = request
        final.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try model.launchClaude(final)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Menu « Ouvrir dans… » : Claude, terminal, éditeur, Finder.
struct OpenInMenu: View {
    @Environment(AppModel.self) private var model
    let project: URL
    var prompt: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Button("Ouvrir dans Claude", systemImage: "sparkles") { model.askClaude(project, prompt: prompt) }
                .buttonStyle(.small)
            Menu {
                Button("\(model.preferences.terminal.label)", systemImage: "terminal") { model.openTerminal(project) }
                Button(model.preferences.editor?.label ?? "Éditeur par défaut", systemImage: "chevron.left.forwardslash.chevron.right") { model.openEditor(project) }
                Button("Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([project]) }
            } label: {
                Label("Ouvrir", systemImage: "arrow.up.forward.app")
            }
            .menuStyle(.button)
            .buttonStyle(.small)
            .fixedSize()
        }
    }
}
