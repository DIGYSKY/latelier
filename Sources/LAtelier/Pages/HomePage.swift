import AppKit
import LAtelierCore
import SwiftUI

/// Accueil de la maquette : salutation, indicateurs, « À traiter », dernières actions.
/// Les indicateurs sans donnée réelle disent à quelle étape ils arrivent.
struct HomePage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var disk = DiskSpace.current()

    var body: some View {
        PageScaffold(title: greeting, subtitle: Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalizedFirst) {
            if let release = model.updates.available {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("L’Atelier \(release.version) est disponible").font(.system(size: 14, weight: .semibold))
                        Text("Vous utilisez la version \(model.updates.currentVersion). La mise à jour passe par un aperçu ; l’ancienne version va à la corbeille.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if let page = release.page {
                        Button("Nouveautés") { NSWorkspace.shared.open(page) }.buttonStyle(PillButtonStyle(kind: .small))
                    }
                    Button("Mettre à jour…") { model.updates.install(release) }.buttonStyle(PillButtonStyle(kind: .smallFilled))
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Theme.accent.opacity(0.12), in: .rect(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accent.opacity(0.3)))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                KpiTile(
                    label: "Stockage", symbol: "internaldrive", color: Theme.accent,
                    value: disk.map { Format.bytes($0.available) } ?? "—",
                    sub: disk.map { "libres sur \(Format.bytes($0.total))" } ?? "espace inconnu",
                    page: .stockageVue
                )
                KpiTile(label: "Projets", symbol: "arrow.triangle.branch", color: .primary,
                        value: model.repos.finishedAt == nil ? "—" : "\(model.repos.repos.count)",
                        sub: projectsSub, page: .depots)
                KpiTile(label: "Sécurité", symbol: "lock.shield", color: Theme.red,
                        value: serious.map { "\($0)" } ?? "—", sub: serious == nil ? "analyse en cours…" : "paquets à faille grave",
                        page: .securite)
                KpiTile(label: "Mises à jour", symbol: "cube.box", color: Theme.orange,
                        value: model.packages.finishedAt == nil ? "—" : "\(model.packages.updates.count)",
                        sub: updatesSub, page: .majs)
            }

            HStack(alignment: .top, spacing: 14) {
                Card(title: "À traiter", trailing: todo.isEmpty ? "Rien en attente" : nil) {
                    if todo.isEmpty {
                        EmptyState(
                            symbol: "checkmark.circle",
                            title: "Rien à traiter pour l’instant",
                            message: "Failles, secrets, commits non poussés et mises à jour apparaîtront ici."
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(todo.enumerated()), id: \.offset) { index, item in
                                if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                                Button { model.selection = item.page } label: {
                                    HStack(spacing: 12) {
                                        IconChip(symbol: item.symbol, color: item.color, size: 28)
                                        Text(item.text).font(.system(size: 13, weight: .medium))
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                                    }
                                    .padding(.vertical, 9)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
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
        .onAppear {
            if model.repos.stale && !model.repos.scanning { model.scanRepos() }
            if model.packages.stale && !model.packages.scanning { model.scanPackages() }
            if model.analysis.stale && !model.analysis.loading { model.scanAnalysis() }
        }
    }

    private var serious: Int? {
        model.analysis.value?.vulnerablePackages.filter { $0.severity >= .high }.count
    }

    private var projectsSub: String {
        guard model.repos.finishedAt != nil else { return "détection en cours…" }
        let pending = model.repos.repos.filter { $0.state != .clean && $0.state != .noRemote && $0.state != .noUpstream }.count
        return pending == 0 ? "dépôts git, tous à jour" : "dépôts git, \(pending) à traiter"
    }

    private var updatesSub: String {
        guard model.packages.finishedAt != nil else { return "vérification en cours…" }
        let major = model.packages.updates.filter { $0.gap == .major }.count
        return major == 0 ? "paquets à mettre à jour" : "dont \(major) majeure\(major > 1 ? "s" : "")"
    }

    private var todo: [(symbol: String, color: Color, text: String, page: Page)] {
        var items: [(symbol: String, color: Color, text: String, page: Page)] = []
        if let analysis = model.analysis.value {
            let critical = analysis.vulnerablePackages.filter { $0.severity == .critical }
            if !critical.isEmpty {
                let projects = Set(critical.map(\.projectName)).count
                items.append(("exclamationmark.shield", Theme.red, "\(critical.count) paquets à faille critique dans \(projects) projet\(projects > 1 ? "s" : "")", .securite))
            }
            if !analysis.secrets.isEmpty {
                items.append(("key", Theme.red, "\(analysis.secrets.count) secret\(analysis.secrets.count > 1 ? "s" : "") commité\(analysis.secrets.count > 1 ? "s" : "")", .securite))
            }
        }
        let unpushed = model.repos.repos.filter { $0.ahead > 0 }.count
        if unpushed > 0 {
            items.append(("arrow.up.circle", Theme.accent, "\(unpushed) dépôt\(unpushed > 1 ? "s" : "") avec des commits non poussés", .modifications))
        }
        let modified = model.repos.repos.filter { !$0.changes.isEmpty }.count
        if modified > 0 {
            items.append(("pencil.circle", Theme.orange, "\(modified) dépôt\(modified > 1 ? "s" : "") avec des modifications non commitées", .modifications))
        }
        let updates = model.packages.updates.count
        if updates > 0 {
            items.append(("arrow.down.circle", Theme.orange, "\(updates) mise\(updates > 1 ? "s" : "") à jour de paquets", .majs))
        }
        let concerning = model.news.concerningSevere
        if concerning > 0 {
            items.append(("newspaper", Theme.red, "\(concerning) avis de sécurité vous concerne\(concerning > 1 ? "nt" : "")", .pourVous))
        }
        let threshold = Double(model.preferences.coverageThreshold)
        let below = (model.coverage.value ?? []).filter { ($0.report?.lines ?? 100) < threshold }.count
        if below > 0 {
            items.append(("checkmark.seal", Theme.orange, "\(below) projet\(below > 1 ? "s" : "") sous le seuil de couverture (\(Int(threshold)) %)", .couverture))
        }
        return items
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
