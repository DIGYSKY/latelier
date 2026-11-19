import LAtelierCore
import SwiftUI

/// Accueil de la maquette : salutation, indicateurs, « À traiter », dernières actions.
/// Les indicateurs sans donnée réelle disent à quelle étape ils arrivent.
struct HomePage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var disk = DiskSpace.current()

    var body: some View {
        PageScaffold(title: greeting, subtitle: Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalizedFirst) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                KpiTile(
                    label: "Stockage", symbol: "internaldrive", color: Theme.accent,
                    value: disk.map { Format.bytes($0.available) } ?? "—",
                    sub: disk.map { "libres sur \(Format.bytes($0.total))" } ?? "espace inconnu",
                    page: .stockageVue
                )
                KpiTile(label: "Projets", symbol: "arrow.triangle.branch", color: .primary, value: "—", sub: "détection à l’étape 3", page: .depots)
                KpiTile(label: "Sécurité", symbol: "lock.shield", color: Theme.red, value: "—", sub: "analyse à l’étape 5", page: .securite)
                KpiTile(label: "Mises à jour", symbol: "cube.box", color: Theme.orange, value: "—", sub: "inventaire à l’étape 4", page: .majs)
            }

            HStack(alignment: .top, spacing: 14) {
                Card(title: "À traiter", trailing: "Rien en attente") {
                    EmptyState(
                        symbol: "checkmark.circle",
                        title: "Rien à traiter pour l’instant",
                        message: "Vulnérabilités, commits non poussés et espace récupérable apparaîtront ici."
                    )
                }

                Card(title: "Dernières actions") {
                    if model.history.isEmpty {
                        Text("Chaque action de L’Atelier sera notée ici, avec sa sortie.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(model.history.prefix(4)) { entry in
                                HistoryRow(entry: entry, expanded: false, compact: true)
                            }
                        }
                        Button("Tout l’historique") { model.selection = .historique }
                            .buttonStyle(.small)
                    }
                }
                .frame(width: 340)
            }
        }
        .task { disk = DiskSpace.current() }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        return hour >= 18 || hour < 5 ? "Bonsoir" : "Bonjour"
    }
}

private struct KpiTile: View {
    @Environment(AppModel.self) private var model
    let label: String
    let symbol: String
    let color: Color
    let value: String
    let sub: String
    let page: Page

    var body: some View {
        Button { model.selection = page } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    IconChip(symbol: symbol, color: color)
                    Text(label).font(.system(size: 14, weight: .semibold))
                }
                Text(value)
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(sub).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .cardBackground()
        }
        .buttonStyle(.plain)
    }
}

/// Espace du volume de démarrage.
struct DiskSpace {
    let available: Int64
    let total: Int64

    static func current() -> DiskSpace? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let available = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity else { return nil }
        return DiskSpace(available: available, total: Int64(total))
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
