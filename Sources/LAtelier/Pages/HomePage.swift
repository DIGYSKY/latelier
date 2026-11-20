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
                        Text(String(localized: "Vous utilisez la version \(model.updates.currentVersion). La mise à jour passe par un aperçu ; l’ancienne version va à la corbeille."))
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if let page = release.page {
                        Button(String(localized: "Nouveautés")) { NSWorkspace.shared.open(page) }.buttonStyle(PillButtonStyle(kind: .small))
                    }
                    Button(String(localized: "Mettre à jour…")) { model.updates.install(release) }.buttonStyle(PillButtonStyle(kind: .smallFilled))
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Theme.accent.opacity(0.12), in: .rect(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accent.opacity(0.3)))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                KpiTile(
                    label: String(localized: "Stockage"), symbol: "internaldrive", color: Theme.accent,
                    value: disk.map { Format.bytes($0.available) } ?? "—",
                    sub: disk.map { String(localized: "libres sur \(Format.bytes($0.total))") } ?? String(localized: "espace inconnu"),
                    page: .stockageVue
                )
                KpiTile(label: String(localized: "Projets"), symbol: "arrow.triangle.branch", color: .primary,
                        value: model.repos.finishedAt == nil ? "—" : "\(model.repos.repos.count)",
                        sub: projectsSub, page: .depots)
                KpiTile(label: String(localized: "Sécurité"), symbol: "lock.shield", color: Theme.red,
                        value: serious.map { "\($0)" } ?? "—", sub: serious == nil ? String(localized: "analyse en cours…") : serious == 0 ? String(localized: "aucun projet actif à faille critique") : (serious! > 1 ? String(localized: "projets actifs à faille critique") : String(localized: "projet actif à faille critique")),
                        page: .securite)
                KpiTile(label: String(localized: "Mises à jour"), symbol: "cube.box", color: Theme.orange,
                        value: model.packages.finishedAt == nil ? "—" : "\(model.packages.updates.count)",
                        sub: updatesSub, page: .majs)
            }

            HStack(alignment: .top, spacing: 14) {
                Card(title: String(localized: "À traiter"), trailing: todo.isEmpty ? String(localized: "Rien en attente") : nil) {
                    if todo.isEmpty {
                        EmptyState(
                            symbol: "checkmark.circle",
                            title: String(localized: "Rien à traiter pour l’instant"),
                            message: String(localized: "Failles, secrets, commits non poussés et mises à jour apparaîtront ici.")
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

                Card(title: String(localized: "Dernières actions")) {
                    if model.history.isEmpty {
                        Text(String(localized: "Chaque action de L’Atelier sera notée ici, avec sa sortie."))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(model.history.prefix(4)) { entry in
                                HistoryRow(entry: entry, expanded: false, compact: true)
                            }
                        }
                        Button(String(localized: "Tout l’historique")) { model.selection = .historique }
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
        model.criticalActiveProjects?.count
    }

    private var projectsSub: String {
        guard model.repos.finishedAt != nil else { return String(localized: "détection en cours…") }
        let pending = model.repos.repos.filter { $0.state != .clean && $0.state != .noRemote && $0.state != .noUpstream }.count
        return pending == 0 ? String(localized: "dépôts git, tous à jour") : String(localized: "dépôts git, \(pending) à traiter")
    }

    private var updatesSub: String {
        guard model.packages.finishedAt != nil else { return String(localized: "vérification en cours…") }
        let major = model.packages.updates.filter { $0.gap == .major }.count
        return major == 0 ? String(localized: "paquets à mettre à jour") : (major > 1 ? String(localized: "dont \(major) majeures") : String(localized: "dont \(major) majeure"))
    }

    private var todo: [(symbol: String, color: Color, text: String, page: Page)] {
        var items: [(symbol: String, color: Color, text: String, page: Page)] = []
        if let analysis = model.analysis.value {
            let active = Set(model.criticalActiveProjects ?? [])
            let critical = analysis.vulnerablePackages.filter { $0.severity == .critical && $0.project.map { active.contains($0.standardizedFileURL) } == true }
            if !critical.isEmpty {
                let projects = active.count
                items.append(("exclamationmark.shield", Theme.red, String(localized: "\(critical.count) paquet\(critical.count > 1 ? "s" : "") à faille critique dans \(projects) projet\(projects > 1 ? "s" : "") actif\(projects > 1 ? "s" : "")"), .securite))
            }
            if !analysis.secrets.isEmpty {
                items.append(("key", Theme.red, (analysis.secrets.count > 1 ? String(localized: "\(analysis.secrets.count) secrets commités") : String(localized: "\(analysis.secrets.count) secret commité")), .securite))
            }
        }
        let unpushed = model.repos.repos.filter { $0.ahead > 0 }.count
        if unpushed > 0 {
            items.append(("arrow.up.circle", Theme.accent, (unpushed > 1 ? String(localized: "\(unpushed) dépôts avec des commits non poussés") : String(localized: "\(unpushed) dépôt avec des commits non poussés")), .modifications))
        }
        let modified = model.repos.repos.filter { !$0.changes.isEmpty }.count
        if modified > 0 {
            items.append(("pencil.circle", Theme.orange, (modified > 1 ? String(localized: "\(modified) dépôts avec des modifications non commitées") : String(localized: "\(modified) dépôt avec des modifications non commitées")), .modifications))
        }
        let updates = model.packages.updates.count
        if updates > 0 {
            items.append(("arrow.down.circle", Theme.orange, (updates > 1 ? String(localized: "\(updates) mises à jour de paquets") : String(localized: "\(updates) mise à jour de paquets")), .majs))
        }
        let concerning = model.news.concerningSevere
        if concerning > 0 {
            items.append(("newspaper", Theme.red, (concerning > 1 ? String(localized: "\(concerning) avis de sécurité vous concernent") : String(localized: "\(concerning) avis de sécurité vous concerne")), .pourVous))
        }
        let threshold = Double(model.preferences.coverageThreshold)
        let below = (model.coverage.value ?? []).filter { ($0.report?.lines ?? 100) < threshold }.count
        if below > 0 {
            items.append(("checkmark.seal", Theme.orange, (below > 1 ? String(localized: "\(below) projets sous le seuil de couverture (\(Int(threshold)) %)") : String(localized: "\(below) projet sous le seuil de couverture (\(Int(threshold)) %)")), .couverture))
        }
        return items
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        return hour >= 18 || hour < 5 ? String(localized: "Bonsoir") : String(localized: "Bonjour")
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
