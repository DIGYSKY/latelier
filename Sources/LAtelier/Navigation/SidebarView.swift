import SwiftUI

/// Barre latérale en accordéon : une seule section ouverte à la fois,
/// celle de l'écran affiché par défaut.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var expanded: SidebarGroup?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            row(.accueil)

            ForEach(SidebarGroup.allCases) { group in
                Section(isExpanded: binding(for: group)) {
                    ForEach(group.entries, id: \.self) { entry in
                        switch entry {
                        case .page(let page):
                            row(page)
                        case .sub(let title, let pages):
                            Text(title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                                .selectionDisabled()
                            ForEach(pages) { row($0).padding(.leading, 12) }
                        }
                    }
                } header: {
                    Label(group.title, systemImage: group.symbol)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .contentShape(.rect)
                        .onTapGesture { toggle(group) }
                }
            }

            Section {
                row(.historique)
                row(.reglages)
            }
        }
        .listStyle(.sidebar)
        .onAppear { expanded = model.selection.group }
        .onChange(of: model.selection) { _, page in
            if let group = page.group { withAnimation(.snappy) { expanded = group } }
        }
    }

    private func row(_ page: Page) -> some View {
        Label(page.title, systemImage: page.symbol).tag(page)
    }

    private func binding(for group: SidebarGroup) -> Binding<Bool> {
        Binding(
            get: { expanded == group },
            set: { open in withAnimation(.snappy) { expanded = open ? group : (expanded == group ? nil : expanded) } }
        )
    }

    /// Cliquer le titre ouvre la section et affiche sa première page.
    private func toggle(_ group: SidebarGroup) {
        if expanded == group {
            withAnimation(.snappy) { expanded = nil }
        } else {
            model.selection = group.firstPage
        }
    }
}
