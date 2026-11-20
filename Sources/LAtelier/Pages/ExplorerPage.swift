import AppKit
import LAtelierCore
import SwiftUI

/// Stockage › Explorateur : treemap des dossiers les plus lourds, avec une description en clair.
struct ExplorerPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.explorer
        let folder = store.current
        let nodes = store.nodes[folder.path]
        PageScaffold(title: "Explorateur") {
            HStack(spacing: 14) {
                ForEach([FolderNode.Kind.safe, .review, .personal, .protected], id: \.self) { kind in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3).fill(Self.colors(kind).fill).frame(width: 12, height: 12)
                        Text(Self.label(kind)).font(.system(size: 12))
                    }
                }
            }
        } content: {
            breadcrumbs(store)
            if let nodes {
                if nodes.isEmpty {
                    Card { EmptyState(symbol: "folder", title: "Dossier vide", message: "Rien de mesurable ici.") }
                } else {
                    let current = nodes.first { $0.id == store.selected } ?? nodes[0]
                    HStack(alignment: .top, spacing: 14) {
                        treemap(nodes, selected: current.id)
                            .frame(maxWidth: .infinity)
                            .frame(height: 520)
                        details(current)
                            .frame(width: 280)
                    }
                    if nodes.contains(where: \.needsPermission) && !model.preferences.allowPersonalFolders {
                        HStack(spacing: 10) {
                            Image(systemName: "hand.raised").foregroundStyle(Theme.muted)
                            Text("Les dossiers hachurés ne sont pas mesurés : macOS demande votre autorisation pour Bureau, Documents et Téléchargements, et protège les données des autres apps.")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            Spacer()
                            Button("Inclure Bureau, Documents, Téléchargements…") { model.allowPersonalFolders() }
                                .buttonStyle(PillButtonStyle(kind: .small))
                        }
                    }
                }
            } else {
                ScanningCard(label: "Mesure de \(folder.abbreviatingHome())…")
            }
        }
        .onAppear { load(folder) }
        .onChange(of: folder) { _, new in load(new) }
        .onChange(of: store.nodes.isEmpty) { load(store.current) }
    }

    private func load(_ folder: URL) {
        model.explorer.load(folder, allowPersonal: model.preferences.allowPersonalFolders, projectRoots: model.projectRoots)
    }

    static func colors(_ kind: FolderNode.Kind) -> (fill: Color, border: Color, ink: Color) {
        switch kind {
        case .safe: (Color(hex: 0x34C759).opacity(0.32), Color(hex: 0x34C759).opacity(0.6), Tag.green.0)
        case .review: (Color(hex: 0xFF9500).opacity(0.30), Color(hex: 0xFF9500).opacity(0.6), Tag.orange.0)
        case .personal: (Color(hex: 0x0A6CDB).opacity(0.20), Color(hex: 0x0A6CDB).opacity(0.45), Tag.blue.0)
        case .protected: (Color.gray.opacity(0.18), Color.gray.opacity(0.4), Theme.muted)
        }
    }

    static func label(_ kind: FolderNode.Kind) -> String {
        switch kind {
        case .safe: "Récupérable sans risque"
        case .review: "À examiner"
        case .personal: "Vos fichiers"
        case .protected: "Protégé"
        }
    }

    private func breadcrumbs(_ store: ExplorerStore) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(store.path.enumerated()), id: \.offset) { index, url in
                if index > 0 { Text("›").foregroundStyle(Theme.muted) }
                Button(index == 0 ? "~" : url.lastPathComponent) { store.open(url) }
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: index == store.path.count - 1 ? .semibold : .regular))
                    .foregroundStyle(index == store.path.count - 1 ? Color.primary : Theme.accent)
            }
            if store.loading.contains(store.current.path) { ProgressView().controlSize(.mini).padding(.leading, 6) }
        }
    }

    private func treemap(_ nodes: [FolderNode], selected: String) -> some View {
        // Les dossiers non mesurés ont une petite place fixe, pour rester visibles.
        let measured = nodes.compactMap(\.bytes).reduce(0, +)
        let values = nodes.map { Double($0.bytes ?? max(1, measured / 40)) }
        let shown = Array(nodes.prefix(40))
        return GeometryReader { geometry in
            let rects = Treemap.layout(Array(values.prefix(40)), width: geometry.size.width, height: geometry.size.height)
            ZStack(alignment: .topLeading) {
                ForEach(rects, id: \.index) { rect in
                    let node = shown[rect.index]
                    block(node, rect: rect, selected: node.id == selected)
                }
            }
        }
    }

    private func block(_ node: FolderNode, rect: Treemap.Rect, selected: Bool) -> some View {
        let colors = Self.colors(node.kind)
        let showText = rect.width > 70 && rect.height > 38
        return Button {
            if model.explorer.selected == node.id, node.isDirectory, !node.needsPermission {
                model.explorer.open(node.url)
            } else {
                model.explorer.selected = node.id
            }
        } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(colors.fill)
                if node.needsPermission {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(ImagePaint(image: Image(systemName: "line.diagonal"), scale: 0.6))
                        .opacity(0.15)
                }
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.primary : colors.border, lineWidth: selected ? 2.5 : 1)
                if showText {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(node.bytes.map(Format.bytes) ?? "non mesuré").font(.system(size: 12)).monospacedDigit().opacity(0.8)
                    }
                    .foregroundStyle(colors.ink)
                    .padding(8)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(width: max(0, rect.width - 3), height: max(0, rect.height - 3))
        .offset(x: rect.x, y: rect.y)
        .help("\(node.name) · \(node.bytes.map(Format.bytes) ?? "non mesuré")\(node.isDirectory ? " · double-clic pour ouvrir" : "")")
        .accessibilityLabel("\(node.name), \(node.bytes.map(Format.bytes) ?? "non mesuré"), \(Self.label(node.kind))")
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if node.isDirectory, !node.needsPermission { model.explorer.open(node.url) }
        })
    }

    private func details(_ node: FolderNode) -> some View {
        let colors = Self.colors(node.kind)
        return VStack(alignment: .leading, spacing: 10) {
            Tag(text: Self.label(node.kind), foreground: colors.ink, background: colors.fill)
            Text(node.name).font(.system(size: 19, weight: .bold)).lineLimit(2)
            Text(node.url.abbreviatingHome()).font(.system(size: 11).monospaced()).foregroundStyle(Theme.muted)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            Text(node.bytes.map(Format.bytes) ?? "Non mesuré").font(.system(size: 26, weight: .bold)).monospacedDigit()
            Text(node.description).font(.system(size: 13)).foregroundStyle(.primary.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                if node.isDirectory && !node.needsPermission {
                    Button("Ouvrir ce dossier") { model.explorer.open(node.url) }
                        .buttonStyle(PillButtonStyle(kind: .smallFilled))
                }
                if let screen = node.screen, let page = Page(rawValue: screen) {
                    Button("Voir dans \(page.title) →") { model.selection = page }
                        .buttonStyle(PillButtonStyle(kind: .small))
                }
                Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
                    .buttonStyle(PillButtonStyle(kind: .small))
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}
