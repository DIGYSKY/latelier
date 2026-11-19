import LAtelierCore
import SwiftUI

/// Stockage › Système : caches utilisateur, logs, corbeille.
struct SystemPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let scan = model.systemScan
        @Bindable var bindable = scan
        PageScaffold(
            page: .systeme,
            subtitle: scan.statusLine ?? "Caches, logs et corbeille. Les caches sont recréés automatiquement par les apps."
        ) {
            Button("Analyser", systemImage: "magnifyingglass") { model.scanSystem() }
                .buttonStyle(.primary)
                .disabled(scan.scanning)
        } content: {
            if scan.scanning {
                ScanningCard(label: "Analyse de ~/Library/Caches, ~/Library/Logs et de la corbeille…")
            } else if scan.groups.isEmpty {
                Card { EmptyState(symbol: "sparkles", title: "Rien à nettoyer", message: "Les caches et les logs sont déjà vides.") }
            } else {
                CleanupList(groups: scan.groups, selection: $bindable.selection)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !scan.scanning, !scan.groups.isEmpty {
                let chosen = scan.items.filter { scan.selection.contains($0.id) && !$0.isLocked }
                CleanupBar(
                    count: chosen.count, bytes: chosen.reduce(0) { $0 + $1.bytes },
                    clear: { scan.selection = [] },
                    review: { review(chosen) }
                )
            }
        }
        .onAppear { if scan.stale && !scan.scanning { model.scanSystem() } }
        // Après un nettoyage lancé depuis cet écran, on réanalyse.
        .onChange(of: scan.stale) { _, stale in if stale && !scan.scanning { model.scanSystem() } }
    }

    private func review(_ chosen: [CleanupItem]) {
        let skipped = model.systemScan.items.filter { $0.isLocked && $0.tag != nil }
        if let plan = CleanupPlanner.plan(title: "Nettoyer : Système", items: chosen, skipped: skipped) {
            model.preview(plan)
        }
    }
}
