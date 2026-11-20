import AppKit
import LAtelierCore
import SwiftUI

/// Stockage › Développement : artefacts de build recréables, par projet.
struct DevPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var kind: DevArtifactScanner.Kind?
    @ViewState private var query = ""
    @ViewState private var showRoots = false

    var body: some View {
        let scan = model.devScan
        @Bindable var bindable = scan
        PageScaffold(
            page: .dev,
            subtitle: scan.statusLine ?? String(localized: "Artefacts de build recréables. Les projets inactifs depuis plus de 3 mois sont cochés par défaut.")
        ) {
            Button("Dossiers (\(model.projectRoots.count))", systemImage: "folder") { showRoots.toggle() }
                .buttonStyle(.secondary)
                .popover(isPresented: $showRoots, arrowEdge: .bottom) { RootsPopover() }
            Button("Analyser", systemImage: "magnifyingglass") { model.scanDev() }
                .buttonStyle(.primary)
                .disabled(scan.scanning || model.projectRoots.isEmpty)
        } content: {
            filters
            if model.projectRoots.isEmpty {
                Card {
                    EmptyState(symbol: "folder.badge.plus", title: String(localized: "Aucun dossier de projets"),
                               message: String(localized: "Ajoutez le dossier où vous rangez vos projets avec le bouton « Dossiers »."))
                }
            } else if scan.scanning {
                ScanningCard(label: String(localized: "Recherche des artefacts dans \(model.projectRoots.map { $0.abbreviatingHome() }.joined(separator: ", "))…"))
            } else if visibleGroups.isEmpty {
                Card { EmptyState(symbol: "sparkles", title: scan.groups.isEmpty ? String(localized: "Aucun artefact trouvé") : String(localized: "Aucun résultat")) }
            } else {
                CleanupList(groups: visibleGroups, selection: $bindable.selection)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !scan.scanning, !visibleGroups.isEmpty {
                let chosen = visibleItems.filter { scan.selection.contains($0.id) && !$0.isLocked }
                CleanupBar(
                    count: chosen.count, bytes: chosen.reduce(0) { $0 + $1.bytes },
                    clear: { scan.selection = [] },
                    review: { review(chosen) }
                )
            }
        }
        .onAppear { if scan.stale && !scan.scanning && !model.projectRoots.isEmpty { model.scanDev() } }
        // Après un nettoyage ou un changement de dossiers, on réanalyse.
        .onChange(of: scan.stale) { _, stale in if stale && !scan.scanning && !model.projectRoots.isEmpty { model.scanDev() } }
        .onChange(of: scan.finishedAt) {
            // Captures et développement : LATELIER_AUTOPREVIEW=1 ouvre l'aperçu (n'exécute rien).
            if ProcessInfo.processInfo.environment["LATELIER_AUTOPREVIEW"] != nil {
                review(visibleItems.filter { scan.selection.contains($0.id) && !$0.isLocked })
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField(String(localized: "Filtrer les projets"), text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: 280, minHeight: 40)
            .background(Theme.cardFill, in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.cardBorder))

            HStack(spacing: 4) {
                chip(nil, String(localized: "Tous"))
                ForEach(DevArtifactScanner.Kind.allCases, id: \.self) { chip($0, $0.label) }
            }
            .padding(4)
            .background(Theme.rowFill, in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.cardBorder))
        }
    }

    private func chip(_ value: DevArtifactScanner.Kind?, _ label: String) -> some View {
        let selected = kind == value
        return Button(label) { kind = value }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background {
                if selected {
                    Capsule().fill(Theme.accent).shadow(color: Theme.accent.opacity(0.3), radius: 4, y: 3)
                }
            }
            .contentShape(.capsule)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Groupes après filtre : seuls les artefacts du type choisi, seuls les projets cherchés.
    private var visibleGroups: [CleanupGroup] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return model.devScan.groups.compactMap { group in
            var group = group
            group.items = group.items
                .compactMap { $0.filtered(kind: kind?.rawValue) }
                .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || $0.detail.localizedCaseInsensitiveContains(q) }
            return group.items.isEmpty ? nil : group
        }
    }

    private var visibleItems: [CleanupItem] { visibleGroups.flatMap(\.items) }

    private func review(_ chosen: [CleanupItem]) {
        let skipped = visibleItems.filter(\.isLocked)
        let title = kind.map { String(localized: "Nettoyer : \($0.label)") } ?? String(localized: "Nettoyer : artefacts de développement")
        if let plan = CleanupPlanner.plan(title: title, items: chosen, skipped: skipped) {
            model.preview(plan)
        }
    }
}

/// Dossiers où chercher les projets.
private struct RootsPopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dossiers de projets").font(.headline)
            Text(String(localized: "L’Atelier cherche les projets dans ces dossiers (et l’onglet Projets aussi)."))
                .font(.callout).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.projectRoots, id: \.self) { root in
                HStack {
                    Image(systemName: "folder").foregroundStyle(Theme.accent)
                    Text(root.abbreviatingHome()).font(.system(size: 13).monospaced())
                    Spacer()
                    Button { model.removeProjectRoot(root) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Retirer ce dossier"))
                }
            }
            Button("Ajouter un dossier…", systemImage: "plus") { pick() }
                .buttonStyle(PillButtonStyle(kind: .small))
        }
        .padding(16)
        .frame(width: 380)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Ajouter")
        if panel.runModal() == .OK { panel.urls.forEach(model.addProjectRoot) }
    }
}
