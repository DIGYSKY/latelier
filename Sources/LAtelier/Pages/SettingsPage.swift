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
                .buttonStyle(.glass)
                .disabled(probing)
        } content: {
            GlassCard(title: "Outils de développement", symbol: "wrench.and.screwdriver") {
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

            GlassCard(title: "À propos", symbol: "info.circle") {
                LabeledContent("Version", value: Self.version)
                LabeledContent("Identifiant", value: AppPaths.bundleIdentifier)
                LabeledContent("Données") {
                    Button("Afficher dans le Finder") {
                        try? FileManager.default.createDirectory(at: AppPaths.supportDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.supportDirectory])
                    }
                    .buttonStyle(.glass)
                }
            }

            GlassCard(title: "À venir (étape 10)", symbol: "slider.horizontal.3") {
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
