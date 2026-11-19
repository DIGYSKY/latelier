import LAtelierCore
import SwiftUI

struct HomePage: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 16)]

    var body: some View {
        PageScaffold(page: .accueil, subtitle: "Ta boîte à outils de développeur sur macOS.") {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(SidebarGroup.allCases) { group in
                    GroupTile(group: group) { model.selection = group.firstPage }
                }
            }

            GlassCard(title: "Dernières actions", symbol: "clock.arrow.circlepath") {
                if model.history.isEmpty {
                    Text("Rien pour l’instant. Chaque action de L’Atelier sera notée ici, avec sa sortie.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.history.prefix(5)) { entry in
                            HistoryRow(entry: entry, expanded: false)
                            if entry.id != model.history.prefix(5).last?.id { Divider() }
                        }
                    }
                    Button("Tout l’historique") { model.selection = .historique }
                        .buttonStyle(.glass)
                }
            }
        }
    }
}

private struct GroupTile: View {
    let group: SidebarGroup
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: group.symbol)
                        .font(.title2)
                        .foregroundStyle(group.tint)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                Text(group.title).font(.title3.weight(.semibold))
                Text(group.tagline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(group.pages.map(\.title).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 172, maxHeight: 172, alignment: .topLeading)
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(group.tint.opacity(0.08)).interactive(), in: .rect(cornerRadius: 22))
    }
}
