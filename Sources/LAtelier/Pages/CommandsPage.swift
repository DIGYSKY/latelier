import AppKit
import LAtelierCore
import SwiftUI

/// Projets › Commandes : scripts, cibles make, recettes just… lancés dans le dossier du projet.
struct CommandsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.projectScope) private var scope
    @ViewState private var project: URL?

    var body: some View {
        let center = model.commandCenter!
        let current = scope ?? project ?? defaultProject
        let set = current.map { center.commands(for: $0) }
        PageScaffold(page: .commandes, subtitle: subtitle(set)) {
            if let current { OpenInMenu(project: current) }
        } content: {
            if scope == nil { projectBar(current) }
            if let current, let set {
                if set.commands.isEmpty {
                    Card {
                        EmptyState(symbol: "terminal", title: String(localized: "Aucune commande détectée"),
                                   message: String(localized: "Ni package.json, Makefile, justfile, Taskfile, compose, Cargo, Maven, Gradle, pyproject ou Package.swift dans ce projet."))
                    }
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        CommandGroups(project: current, set: set)
                            .frame(maxWidth: .infinity)
                        VStack(spacing: 14) {
                            OutputPanel(project: current)
                            SuggestionsCard(project: current, set: set)
                        }
                        .frame(width: 380)
                    }
                }
            } else if model.repos.scanning {
                ScanningCard(label: String(localized: "Recherche des projets…"))
            } else {
                Card { EmptyState(symbol: "folder", title: String(localized: "Aucun projet"), message: String(localized: "Ajoutez un dossier de projets dans Réglages › Projets.")) }
            }
        }
        .onAppear { model.ensureRepos() }
    }

    private var defaultProject: URL? {
        let known = Set(model.knownProjects)
        if let recent = model.commandCenter.recentProjects.first(where: known.contains) { return recent }
        return model.repos.selected?.url
    }

    private func subtitle(_ set: ProjectCommandSet?) -> String {
        guard let set, !set.sources.isEmpty else { return String(localized: "Les commandes de vos projets, lancées dans leur dossier") }
        return String(localized: "Détectées dans \(set.sources.joined(separator: ", ")) · lancées dans le dossier du projet")
    }

    @ViewBuilder
    private func projectBar(_ current: URL?) -> some View {
        let known = model.knownProjects
        let recent = Array(model.commandCenter.recentProjects.filter(known.contains).prefix(4))
        let chips = current.map { recent.contains($0) ? recent : [$0] + recent.prefix(3) } ?? recent
        HStack(spacing: 10) {
            if !chips.isEmpty {
                GlassSegments(selection: Binding(get: { current ?? chips[0] }, set: { project = $0 }),
                              items: chips.map { ($0, model.projectName($0)) })
            }
            Menu {
                ForEach(known.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }, id: \.self) { url in
                    Button(model.projectName(url)) { project = url }
                }
            } label: {
                Label("Autre projet", systemImage: "folder")
            }
            .menuStyle(.button)
            .buttonStyle(.small)
            .fixedSize()
            Spacer()
        }
    }
}

// MARK: - Groupes

private struct CommandGroups: View {
    @Environment(AppModel.self) private var model
    let project: URL
    let set: ProjectCommandSet

    var body: some View {
        let center = model.commandCenter!
        let pinned = set.commands.filter { center.isPinned(project, $0) }
        VStack(spacing: 14) {
            if !pinned.isEmpty { group(String(localized: "Épinglées"), pinned) }
            ForEach(CommandCategory.allCases, id: \.self) { category in
                let commands = set.commands.filter { $0.category == category && !center.isPinned(project, $0) }
                if !commands.isEmpty { group(category.title, commands) }
            }
        }
    }

    private func group(_ title: String, _ commands: [ProjectCommand]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 6)
            ForEach(commands) { command in
                Rectangle().fill(Theme.hairline).frame(height: 1)
                CommandRow(project: project, command: command)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .cardBackground()
    }
}

private struct CommandRow: View {
    @Environment(AppModel.self) private var model
    let project: URL
    let command: ProjectCommand

    var body: some View {
        let center = model.commandCenter!
        let key = center.key(project, command)
        let running = center.isRunning(key)
        let pinned = center.isPinned(project, command)
        let last = center.lastRun(project, command)
        HStack(spacing: 12) {
            Button {
                center.togglePin(project, command)
            } label: {
                Image(systemName: pinned ? "star.fill" : "star")
                    .font(.system(size: 14))
                    .foregroundStyle(pinned ? Color(hex: 0xE8A400) : Theme.muted)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pinned ? String(localized: "Désépingler \(command.name)") : String(localized: "Épingler \(command.name)"))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(command.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(command.source)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(Theme.hairline))
                    if command.isSensitive {
                        Tag(text: "sensible", foreground: Tag.orange.0, background: Tag.orange.1)
                            .help(String(localized: "Déploiement, migration ou suppression : un aperçu est demandé avant de lancer."))
                    }
                }
                Text("$ \(command.commandLine)")
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(command.body ?? command.commandLine)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(lastLabel(last))
                .font(.system(size: 12))
                .foregroundStyle(last.map { $0.status != nil && !$0.succeeded } == true ? Tag.red.0 : Theme.muted)
                .lineLimit(1)
                .frame(width: 130, alignment: .trailing)

            Button {
                if running { center.stop(key) } else { run() }
            } label: {
                Label(running ? String(localized: "Arrêter") : String(localized: "Exécuter"), systemImage: running ? "stop.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 30)
                    .background(running ? Color(hex: 0x1D1D1F) : Theme.accent, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .frame(width: 104, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(running ? Theme.accent.opacity(0.08) : (center.focus == key ? Theme.raised.opacity(0.4) : .clear))
        .contentShape(.rect)
        .onTapGesture { if center.runs[key] != nil { center.focus = key } }
        .contextMenu {
            Button(String(localized: "Exécuter et enregistrer les performances")) {
                model.recorder.arm(project: project, label: command.name)
                run()
            }
            .disabled(running)
            Button(String(localized: "Copier la commande")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command.spec.displayString, forType: .string)
            }
            if let last, !last.errorTail.isEmpty {
                Button(String(localized: "Demander à Claude de corriger")) {
                    model.askClaude(project, prompt: ClaudePrompts.failedCommand(command.commandLine, tail: last.errorTail),
                                    context: String(localized: "« \(command.name) » échoue"))
                }
            }
        }
    }

    private func run() {
        if command.isSensitive {
            model.preview(CommandCenter.sensitivePlan(command, project: project))
        } else {
            model.commandCenter.start(command, in: project)
        }
    }

    private func lastLabel(_ record: CommandRunRecord?) -> String {
        guard let record else { return String(localized: "jamais lancée") }
        let when = FrenchDate.relative(record.date)
        guard let status = record.status else { return "■ \(when)" }
        if status == 0 { return "✓ \(when) · \(Format.duration(record.duration))" }
        return "✗ \(when)"
    }
}

// MARK: - Sortie

private struct OutputPanel: View {
    @Environment(AppModel.self) private var model
    let project: URL

    var body: some View {
        let center = model.commandCenter!
        let key = center.focus.flatMap { center.runs[$0]?.project == project ? $0 : nil }
            ?? center.runs.first { $0.value.project == project }?.key
        let run = key.flatMap { center.runs[$0] }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(run?.running == true ? Tag.green.0 : (run.map { $0.status == 0 || $0.stopped } ?? true ? Theme.muted : Tag.red.0))
                    .frame(width: 8, height: 8)
                Text(run.map { "$ \($0.command.commandLine)" } ?? String(localized: "Sortie"))
                    .font(.system(size: 12, weight: .semibold).monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let run {
                    Text(run.stateLabel).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            ConsoleBlock(text: run?.lines.suffix(300).joined(separator: "\n") ?? String(localized: "Lancez une commande : sa sortie s’affiche ici en direct."), maxHeight: 300)
            if let run, let key {
                HStack(spacing: 8) {
                    if run.running {
                        Button("Arrêter", systemImage: "stop.fill") { center.stop(key) }.buttonStyle(.small)
                    } else if run.status != 0 && !run.stopped {
                        Button("Demander à Claude", systemImage: "sparkles") {
                            model.askClaude(project, prompt: ClaudePrompts.failedCommand(run.command.commandLine, tail: Array(run.lines.suffix(40))),
                                            context: String(localized: "« \(run.command.name) » échoue"))
                        }
                        .buttonStyle(.small)
                    }
                    Spacer()
                    Button(String(localized: "Copier la sortie")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(run.lines.joined(separator: "\n"), forType: .string)
                    }
                    .buttonStyle(.small)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

// MARK: - Suggestions

private struct SuggestionsCard: View {
    @Environment(AppModel.self) private var model
    let project: URL
    let set: ProjectCommandSet

    var body: some View {
        let center = model.commandCenter!
        let suggestions = set.suggestions.filter { !center.isDismissed(project, $0.id) }
        let port = center.busyPort(in: project)
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggestions").font(.system(size: 15, weight: .semibold))
            if suggestions.isEmpty && port == nil {
                Text("Rien à suggérer pour ce projet.").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            if let port, !center.isDismissed(project, "port") {
                item(title: String(localized: "Le port \(String(port.port)) est occupé"),
                     why: String(localized: "« \(port.command) » a échoué : un autre processus écoute déjà sur ce port."),
                     preview: String(localized: "lsof -iTCP:\(String(port.port)) -sTCP:LISTEN")) {
                    Button(String(localized: "Voir dans Réseau")) { model.selection = .reseau }.buttonStyle(.small)
                    claudeButton(String(localized: "Le port \(String(port.port)) est occupé"), String(localized: "« \(port.command) » échoue sur EADDRINUSE. Rends le port configurable ou libère-le proprement."))
                    Button(String(localized: "Ignorer")) { center.dismiss(project, id: "port") }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            ForEach(suggestions) { suggestion in
                item(title: suggestion.title, why: suggestion.why, preview: suggestion.preview) {
                    if let plan = CommandCenter.suggestionPlan(suggestion, project: project) {
                        Button(String(localized: "Ajouter au projet…")) { model.preview(plan) }
                            .buttonStyle(PillButtonStyle(kind: .smallFilled))
                            .fixedSize()
                    }
                    claudeButton(suggestion.title, suggestion.why)
                    Button(String(localized: "Ignorer")) { center.dismiss(project, id: suggestion.id) }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func claudeButton(_ title: String, _ why: String) -> some View {
        Button(String(localized: "Demander à Claude")) {
            model.askClaude(project, prompt: ClaudePrompts.suggestion(title: title, why: why), context: title)
        }
        .buttonStyle(.small)
        .fixedSize()
    }

    private func item<Actions: View>(title: String, why: String, preview: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(why).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Text(preview)
                .font(.system(size: 12).monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.raised.opacity(0.7), in: .rect(cornerRadius: 8, style: .continuous))
            HStack(spacing: 8) { actions() }
        }
        .padding(12)
        .background(Theme.raised.opacity(0.35), in: .rect(cornerRadius: 14, style: .continuous))
    }
}

extension FrenchDate {
    /// « il y a 3 j », « hier », « à l’instant ».
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return String(localized: "à l’instant") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale.current
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
