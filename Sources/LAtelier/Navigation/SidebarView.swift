import SwiftUI

/// Barre latérale de la maquette : accordéon (une section ouverte à la fois, par défaut
/// celle de l'écran affiché), pastille blanche pour la page active, sous-pages en retrait.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var open: SidebarGroup?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                brand
                PageRow(page: .accueil, level: 1)

                ForEach(SidebarGroup.allCases) { group in
                    if !group.showsChildren {
                        PageRow(page: group.firstPage, level: 1, badge: badge(group))
                    } else {
                    GroupRow(group: group, open: open == group, inside: model.selection.group == group, badge: badge(group)) {
                        withAnimation(.snappy(duration: 0.25)) { open = open == group ? nil : group }
                    }
                    if open == group {
                        ForEach(group.entries, id: \.self) { entry in
                            switch entry {
                            case .page(let page):
                                PageRow(page: page, level: 2, badge: page == .pourVous ? badge(.news) : nil)
                            case .sub(let title, let pages):
                                SubLabel(title: title, symbol: "app")
                                ForEach(pages) { PageRow(page: $0, level: 3) }
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    }
                }

                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 12).padding(.vertical, 8)
                PageRow(page: .historique, level: 1)
                PageRow(page: .reglages, level: 1)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
        }
        .scrollIndicators(.never)
        .onAppear { open = model.selection.group }
        .onChange(of: model.selection) { _, page in
            if let group = page.group, group != open, group.showsChildren {
                withAnimation(.snappy(duration: 0.25)) { open = group }
            }
        }
    }

    /// Pastille d'une section : news non lues, failles graves, mises à jour (seulement si déjà connues).
    private func badge(_ group: SidebarGroup) -> Badge? {
        switch group {
        case .news:
            let unread = model.news.unreadForYou
            return unread > 0 ? Badge(text: "\(unread)", color: Theme.accent) : nil
        case .projets:
            // Projets actifs touchés par une faille critique (pas chaque paquet de chaque vieux projet).
            guard let count = model.criticalActiveProjects?.count, count > 0 else { return nil }
            return Badge(text: "\(count)", color: Theme.red)
        case .paquets:
            let updates = model.packages.updates.count
            return updates > 0 ? Badge(text: "\(updates)", color: Theme.orange) : nil
        case .stockage, .performance, .serveurs:
            return nil
        }
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(systemName: "wrench.adjustable")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Theme.accent, in: .rect(cornerRadius: 9, style: .continuous))
            Text("L’Atelier").font(.system(size: 16, weight: .bold)).tracking(-0.2)
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 14)
    }
}

/// Une page. Niveau 1 : racine ; 2 : dans une section ; 3 : dans un sous-groupe.
struct Badge {
    var text: String
    var color: Color
}

private struct BadgeView: View {
    let badge: Badge

    var body: some View {
        Text(badge.text)
            .font(.system(size: 11, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(minWidth: 20, minHeight: 18)
            .background(badge.color, in: .capsule)
    }
}

private struct PageRow: View {
    @Environment(AppModel.self) private var model
    let page: Page
    let level: Int
    var badge: Badge?
    @ViewState private var hovering = false

    var body: some View {
        let active = model.selection == page || (page == .depots && model.selection.group == .projets)
        Button {
            // Projets : un clic revient à la liste des dépôts.
            if page == .depots { model.openRepo = nil }
            if page == .serveurs { model.ssh.close() }
            model.selection = page
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: level == 1 ? 15 : 13))
                    .foregroundStyle(active ? Theme.accent : Color.primary)
                    .frame(width: 20)
                Text(page.title)
                    .font(.system(size: level == 1 ? 14 : 13, weight: active ? .semibold : .regular))
                Spacer(minLength: 0)
                if let badge { BadgeView(badge: badge) }
            }
            .padding(.leading, level == 1 ? 12 : level == 2 ? 38 : 56)
            .padding(.trailing, 12)
            .frame(minHeight: level == 1 ? 36 : 32)
            .contentShape(.rect)
            .background { RowBackground(active: active, hovering: hovering) }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Titre de section : ouvre ou ferme, chevron qui tourne.
private struct GroupRow: View {
    let group: SidebarGroup
    let open: Bool
    /// La page affichée est dans cette section.
    let inside: Bool
    var badge: Badge?
    let toggle: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: group.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(inside ? Theme.accent : Color.primary)
                    .frame(width: 20)
                Text(group.title).font(.system(size: 14, weight: inside ? .semibold : .regular))
                Spacer(minLength: 0)
                if let badge, !open { BadgeView(badge: badge) }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.muted)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .contentShape(.rect)
            .background { RowBackground(active: inside && !open, hovering: hovering) }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityValue(open ? "ouvert" : String(localized: "fermé"))
    }
}

private struct SubLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(title).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(Theme.muted)
        .padding(.leading, 40)
        .frame(minHeight: 28)
    }
}

private struct RowBackground: View {
    let active: Bool
    let hovering: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(active ? Theme.raised : (hovering ? Theme.raised.opacity(0.45) : .clear))
            .shadow(color: active ? Theme.shadow.opacity(0.12) : .clear, radius: 4, y: 2)
    }
}
