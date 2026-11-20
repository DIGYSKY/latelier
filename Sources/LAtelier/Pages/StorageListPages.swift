import LAtelierCore
import SwiftUI

/// Page de nettoyage générique (Caches, Applications › Nettoyage) : analyse, liste à cocher, barre, aperçu.
struct ScanListPage<Banner: View>: View {
    @Environment(AppModel.self) private var model
    let page: Page
    let store: ScanStore
    let subtitle: String
    let scanningLabel: String
    let emptyTitle: String
    let emptyMessage: String
    let planTitle: String
    let scan: () -> Void
    var verb = "à mettre à la corbeille"
    @ViewBuilder var banner: Banner

    var body: some View {
        @Bindable var bindable = store
        PageScaffold(page: page, subtitle: store.statusLine.map { "\(subtitle) · \($0)" } ?? subtitle) {
            Button("Analyser", systemImage: "magnifyingglass", action: scan)
                .buttonStyle(.primary)
                .disabled(store.scanning)
        } content: {
            banner
            if store.scanning {
                ScanningCard(label: scanningLabel)
            } else if store.groups.isEmpty {
                Card { EmptyState(symbol: "sparkles", title: emptyTitle, message: emptyMessage) }
            } else {
                CleanupList(groups: store.groups, selection: $bindable.selection)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !store.scanning, !store.groups.isEmpty {
                let chosen = store.items.filter { store.selection.contains($0.id) && !$0.isLocked }
                CleanupBar(
                    count: chosen.count, bytes: chosen.reduce(0) { $0 + $1.bytes }, verb: verb,
                    clear: { store.selection = [] },
                    review: {
                        let skipped = store.items.filter { $0.isLocked && $0.tag != nil }
                        if let plan = CleanupPlanner.plan(title: planTitle, items: chosen, skipped: skipped) { model.preview(plan) }
                    }
                )
            }
        }
        .onAppear { if store.stale && !store.scanning { scan() } }
        .onChange(of: store.stale) { _, stale in if stale && !store.scanning { scan() } }
    }
}

/// Stockage › Caches de paquets.
struct CachesPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScanListPage(
            page: .caches, store: model.cacheScan,
            subtitle: "Nettoyés avec la commande officielle de chaque outil quand elle existe. Les toolchains ne sont jamais touchées",
            scanningLabel: "Mesure des caches npm, pnpm, Go, Cargo, Maven, Xcode et ~/.cache…",
            emptyTitle: "Aucun cache notable", emptyMessage: "Les caches des gestionnaires de paquets sont vides ou absents.",
            planTitle: "Nettoyer : caches de paquets", scan: model.scanCaches, verb: "à libérer"
        ) { EmptyView() }
    }
}

/// Stockage › Applications › Nettoyage : restes d'apps supprimées, liens morts, installations interrompues.
struct AppsCleanupPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScanListPage(
            page: .appsNettoyage, store: model.leftoverScan,
            subtitle: "Restes d’apps déjà supprimées. Pour retirer une app installée, utilisez le Désinstalleur",
            scanningLabel: "Recherche des données d’apps qui ne sont plus installées…",
            emptyTitle: "Aucun reste d’app", emptyMessage: "Toutes les données de ~/Library appartiennent à des apps installées.",
            planTitle: "Nettoyer : restes d’applications", scan: model.scanLeftovers
        ) {
            if !model.deadLinks.isEmpty { deadLinksBanner }
            Button("Ouvrir le Désinstalleur →") { model.selection = .desinstalleur }
                .buttonStyle(.link)
                .font(.system(size: 13))
        }
    }

    private var deadLinksBanner: some View {
        let links = model.deadLinks
        return HStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.system(size: 16)).foregroundStyle(Color(hex: 0x4A2A8A))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(links.count) lien\(links.count > 1 ? "s" : "") mort\(links.count > 1 ? "s" : "") dans /usr/local/bin")
                    .font(.system(size: 14, weight: .semibold))
                Text(links.map { "\($0.url.lastPathComponent) → \(DeadLinks.appName($0))" }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Supprimer (mot de passe admin)…") {
                if let plan = model.deadLinksPlan { model.preview(plan) }
            }
            .buttonStyle(PillButtonStyle(kind: .small))
            .disabled(model.deadLinksPlan == nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color(hex: 0x6E4BD8).opacity(0.12), in: .rect(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color(hex: 0x6E4BD8).opacity(0.3)))
    }
}

/// Stockage › Docker : lu avec `docker system df -v`, nettoyé avec la CLI.
struct DockerPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var bindable = model
        let store = model.docker
        let report = store.value
        let groups = report.map { DockerScanner.groups($0, docker: model.dockerPath) } ?? []
        PageScaffold(page: .docker, subtitle: "Lu via docker system df -v · nettoyé via la CLI Docker") {
            if let report { statusPill(report) }
            Button("Analyser", systemImage: "magnifyingglass") { model.scanDocker() }
                .buttonStyle(.primary)
                .disabled(store.loading)
        } content: {
            if !model.preferences.includeDocker {
                Card {
                    EmptyState(symbol: "shippingbox", title: "Docker est exclu des analyses",
                               message: "Réglages › Stockage › Inclure Docker. Le bouton Analyser lit quand même Docker à la demande.")
                }
            }
            if store.loading && report == nil {
                ScanningCard(label: "Lecture de docker system df -v…")
            } else if let report {
                switch report.state {
                case .notInstalled:
                    Card { EmptyState(symbol: "shippingbox", title: "Docker n’est pas installé", message: "La CLI docker est introuvable.") }
                case .notRunning(let message):
                    Card {
                        EmptyState(symbol: "pause.circle", title: "Docker n’est pas démarré",
                                   message: "L’Atelier ne le démarre pas pour vous. Lancez Docker Desktop puis Analyser. (\(message))")
                    }
                case .ready:
                    stats(report)
                    if groups.isEmpty {
                        Card { EmptyState(symbol: "sparkles", title: "Rien à nettoyer", message: "Pas d’image, de conteneur ni de volume inutilisé.") }
                    } else {
                        CleanupList(groups: groups, selection: $bindable.dockerSelection)
                        if groups.contains(where: { $0.tone == .data }) && groups.filter({ $0.tone == .data }).flatMap(\.items).contains(where: { model.dockerSelection.contains($0.id) }) {
                            Label("Vous avez coché un volume de données. Il sera supprimé définitivement (pas de corbeille pour Docker).",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.red)
                        }
                    }
                    Label("L’espace revient progressivement : Docker stocke tout dans un disque virtuel (Docker.raw) qui se réduit au fil du temps.",
                          systemImage: "info.circle")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !groups.isEmpty {
                let chosen = groups.flatMap(\.items).filter { model.dockerSelection.contains($0.id) && !$0.isLocked }
                CleanupBar(count: chosen.count, bytes: chosen.reduce(0) { $0 + $1.bytes }, verb: "à supprimer via docker",
                           clear: { model.dockerSelection = [] }) {
                    let skipped = groups.flatMap(\.items).filter { $0.isLocked }
                    let data = chosen.contains { $0.risk == .danger }
                    if var plan = CleanupPlanner.plan(
                        title: "Nettoyer : Docker", items: chosen, skipped: skipped,
                        summary: data
                            ? "Attention : un volume de données est coché. Docker le supprime définitivement, sans corbeille."
                            : "Nettoyé avec la CLI Docker : ce qui est supprimé ne passe pas par la corbeille, mais tout est recréable."
                    ) {
                        plan.stopOnFailure = false
                        model.preview(plan)
                    }
                }
            }
        }
        .onAppear { if model.preferences.includeDocker && store.stale && !store.loading { model.scanDocker() } }
        .onChange(of: store.stale) { _, stale in if model.preferences.includeDocker && stale && !store.loading { model.scanDocker() } }
        .onChange(of: store.finishedAt) {
            model.dockerSelection = Set(groups.flatMap(\.items).filter { $0.selectedByDefault && !$0.isLocked }.map(\.id))
        }
    }

    private func statusPill(_ report: DockerReport) -> some View {
        let running = report.state == .ready
        return HStack(spacing: 6) {
            Circle().fill(running ? Tag.green.0 : Theme.muted).frame(width: 8, height: 8)
            Text(running ? "Docker en cours d’exécution" + (report.runningCount > 0 ? " · \(report.runningCount) conteneur\(report.runningCount > 1 ? "s" : "") actif\(report.runningCount > 1 ? "s" : "")" : "") : "Docker arrêté")
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .background(Theme.cardFill, in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.cardBorder))
    }

    private func stats(_ report: DockerReport) -> some View {
        HStack(spacing: 12) {
            StatTile(label: "Images", value: Format.bytes(report.imageBytes))
            StatTile(label: "Conteneurs arrêtés", value: Format.bytes(report.stoppedBytes))
            StatTile(label: "Build cache", value: Format.bytes(report.buildCache))
            StatTile(label: "Volumes", value: Format.bytes(report.volumeBytes))
        }
    }
}
