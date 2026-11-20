import AppKit
import LAtelierCore
import SwiftUI

struct SettingsPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var tools: [ToolProbe.Status] = []
    @ViewState private var probing = false

    var body: some View {
        PageScaffold(page: .reglages, subtitle: "Outils détectés et informations sur l’app.") {
            Button("Revérifier", systemImage: "arrow.clockwise") { Task { await probe() } }
                .buttonStyle(.secondary)
                .disabled(probing)
        } content: {
            Card(title: "Outils de développement") {
                Text("L’Atelier s’appuie sur ces outils. Ceux qui manquent désactivent seulement les fonctions qui en dépendent.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if tools.isEmpty {
                    ProgressView("Recherche des outils…").frame(maxWidth: .infinity).padding()
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        ForEach(tools) { status in
                            GridRow {
                                Image(systemName: status.installed ? "checkmark.circle.fill" : "minus.circle")
                                    .foregroundStyle(status.installed ? .green : .secondary)
                                Text(status.tool.name).font(.body.monospaced())
                                Text(status.version ?? (status.installed ? "version inconnue" : "non installé"))
                                    .foregroundStyle(status.installed ? .primary : .secondary)
                                    .lineLimit(1)
                                Text(status.path ?? "")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    Text("\(tools.filter(\.installed).count) sur \(tools.count) installés")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ProjectToolsSettings()
            NewsSettings()

            Card(title: "À propos") {
                LabeledContent("Version", value: Self.version)
                LabeledContent("Identifiant", value: AppPaths.bundleIdentifier)
                LabeledContent("Données") {
                    Button("Afficher dans le Finder") {
                        try? FileManager.default.createDirectory(at: AppPaths.supportDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.supportDirectory])
                    }
                    .buttonStyle(.secondary)
                }
            }

            Card(title: "À venir (étape 10)") {
                Text("Dossiers de projets, sources de paquets et de news, règles de nettoyage, notifications, mises à jour de l’app.")
                    .foregroundStyle(.secondary)
            }
        }
        .task { await probe() }
    }

    private func probe() async {
        probing = true
        tools = await ToolProbe(runner: model.runner).probe()
        probing = false
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}

/// Ouvrir dans…, couverture et Enregistreur.
private struct ProjectToolsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Card(title: "Projets") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Terminal")
                    Picker("Terminal", selection: $preferences.terminal) {
                        ForEach(TerminalApp.allCases, id: \.self) { app in
                            Text(app.label + (app.installedURL == nil ? " (non installé)" : "")).tag(app)
                        }
                    }
                    .labelsHidden().fixedSize()
                    Text("Pour « Ouvrir dans Claude » et « Terminal ».").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Éditeur")
                    Picker("Éditeur", selection: $preferences.editor) {
                        Text("App par défaut du Finder").tag(EditorApp?.none)
                        ForEach(EditorApp.installed, id: \.self) { Text($0.label).tag(EditorApp?.some($0)) }
                    }
                    .labelsHidden().fixedSize()
                    Text("Pour « Ouvrir dans l’éditeur ».").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Claude Code")
                    Text(model.runner.locator.locate("claude")?.path ?? "non trouvé : npm install -g @anthropic-ai/claude-code")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .gridCellColumns(2)
                }
                GridRow {
                    Text("Seuil de couverture")
                    Picker("Seuil de couverture", selection: $preferences.coverageThreshold) {
                        ForEach([60, 70, 80, 90], id: \.self) { Text("\($0) %").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Text("Sous ce seuil, le projet est signalé.").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Enregistreur")
                    Picker("Enregistreur", selection: $preferences.recorderPolicy) {
                        ForEach(RecorderPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Text("Quand un processus de dev démarre dans un projet.").foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct NewsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Card(title: "News") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Lecture des sources")
                    Picker("Lecture des sources", selection: $preferences.newsIntervalHours) {
                        ForEach([1, 3, 6, 12, 24], id: \.self) { Text($0 == 1 ? "toutes les heures" : "toutes les \($0) h").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Text("Tant que l’app est ouverte. Le bouton ↻ relit tout de suite.").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Notifications")
                    Toggle("Faille critique qui vous concerne", isOn: $preferences.newsNotifications)
                    Text("Seulement quand la version installée est dans l’intervalle touché.").foregroundStyle(.secondary)
                }
            }
        }
    }
}
