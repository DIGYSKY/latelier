import LAtelierCore
import SwiftUI

/// Stockage › Vue d’ensemble : répartition du disque entier, récupérable par écran, dernières suppressions.
struct StorageOverviewPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var selected: DiskCategory.ID? = .dev

    var body: some View {
        let store = model.overview
        PageScaffold(page: .stockageVue, subtitle: subtitle) {
            Button("Explorer", systemImage: "square.grid.3x3.square") { model.selection = .explorateur }
                .buttonStyle(.secondary)
            Button("Sonar", systemImage: "dot.radiowaves.left.and.right") { model.selection = .sonar }
                .buttonStyle(.secondary)
            Button("Analyser", systemImage: "magnifyingglass") { analyzeAll() }
                .buttonStyle(.primary)
                .disabled(anyScanning)
        } content: {
            if let overview = store.value {
                diskCard(overview)
            } else {
                ScanningCard(label: String(localized: "Mesure du disque : apps, outils de développement, images, vidéos, musique…"))
            }
            if anyScanning { progress }
            recoverableCards
            recentDeletions
        }
        .onAppear {
            if store.stale && !store.loading { model.scanOverview() }
            if model.devScan.stale && !model.devScan.scanning { model.scanDev() }
            if model.systemScan.stale && !model.systemScan.scanning { model.scanSystem() }
            if model.cacheScan.stale && !model.cacheScan.scanning { model.scanCaches() }
            if model.leftoverScan.stale && !model.leftoverScan.scanning { model.scanLeftovers() }
            if model.preferences.includeDocker && model.docker.stale && !model.docker.loading { model.scanDocker() }
        }
        .onChange(of: store.stale) { _, stale in if stale && !store.loading { model.scanOverview() } }
    }

    private var subtitle: String {
        guard let overview = model.overview.value, let finished = model.overview.finishedAt else { return String(localized: "Tout le disque, pas seulement ce qui est nettoyable") }
        return String(localized: "Dernière analyse à \(finished.formatted(date: .omitted, time: .shortened)) · \(Format.duration(overview.duration))")
    }

    private var anyScanning: Bool {
        model.overview.loading || model.systemScan.scanning || model.devScan.scanning || model.cacheScan.scanning
            || model.leftoverScan.scanning || model.docker.loading
    }

    private func analyzeAll() {
        model.scanOverview()
        model.scanSystem()
        model.scanDev()
        model.scanCaches()
        model.scanLeftovers()
        if model.preferences.includeDocker { model.scanDocker() }
    }

    // MARK: Répartition

    static func info(_ id: DiskCategory.ID) -> (name: String, color: Color, description: String, page: Page, action: String) {
        switch id {
        case .macos: ("macOS", Color(hex: 0x5C5C66), "Le système lui-même, sur un volume scellé en lecture seule. Jamais modifiable.", .explorateur, "Explorer")
        case .sysdata: ("Données système", Color(hex: 0x9A9AA3), "Swap, caches, journaux et données des apps dans ~/Library (hors Xcode, compté dans Développeur, et hors données protégées des autres apps).", .systeme, "Nettoyer le système")
        case .apps: ("Applications", Color(hex: 0x0A6CDB), "Apps de /Applications et ~/Applications.", .desinstalleur, "Ouvrir le désinstalleur")
        case .dev: ("Développeur", Color(hex: 0x6E4BD8), "Xcode, toolchains, caches de paquets, Homebrew et vos projets (artefacts compris).", .dev, "Voir les artefacts")
        case .docs: ("Documents", Color(hex: 0xE8890C), "Documents et Bureau, hors iCloud.", .sonar, "Explorer au sonar")
        case .images: ("Images", Color(hex: 0xD6336C), "~/Pictures, hors Photothèque (non parcourue).", .sonar, "Explorer au sonar")
        case .videos: ("Vidéos", Color(hex: 0xB42318), "Films et enregistrements d’écran de ~/Movies.", .sonar, "Explorer au sonar")
        case .music: ("Musique", Color(hex: 0x1E8A45), "~/Music, hors bibliothèque Musique.", .sonar, "Explorer au sonar")
        case .downloads: ("Téléchargements", Color(hex: 0x00879E), "Installeurs, images disque et archives oubliés.", .sonar, "Trier au sonar")
        case .users: ("Autres utilisateurs", Color(hex: 0x8A6D3B), "Autres comptes du Mac : lecture seule sans droits administrateur.", .explorateur, "Explorer")
        case .trash: ("Corbeille", Color(hex: 0x3A3A40), "~/.Trash", .systeme, "Vider la corbeille")
        case .other: ("Autres", Color(hex: 0xC9B88A), "Tout ce qui n’est pas classé : instantanés locaux, conteneurs des apps, dossiers non mesurés, machines virtuelles…", .explorateur, "Explorer")
        }
    }

    private func diskCard(_ overview: DiskOverview) -> some View {
        let shown = overview.categories.filter { ($0.bytes ?? 0) > 0 }
        let total = max(Double(overview.total), 1)
        let current = overview.categories.first { $0.id == selected }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(overview.volumeName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                    (Text("\(Format.bytes(overview.available)) libres ").font(.system(size: 26, weight: .bold))
                        + Text(String(localized: "sur \(Format.bytes(overview.total)) · \(Format.bytes(overview.used)) utilisés, répartis ci-dessous"))
                        .font(.system(size: 14)).foregroundStyle(Theme.muted))
                    if overview.purgeable > 500_000_000 {
                        Text(String(localized: "dont \(Format.bytes(overview.purgeable)) « purgeables » que macOS libère seul au besoin"))
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text("Récupérable sans risque").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Text(Format.bytes(safeItems.reduce(0) { $0 + $1.bytes })).font(.system(size: 22, weight: .bold)).foregroundStyle(Tag.green.0)
                    Button(String(localized: "Nettoyer le sans-risque…")) { cleanSafe() }
                        .buttonStyle(PillButtonStyle(kind: .smallFilled))
                        .disabled(safeItems.isEmpty)
                }
            }

            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(shown) { category in
                        let info = Self.info(category.id)
                        Button { selected = selected == category.id ? nil : category.id } label: {
                            Rectangle().fill(info.color)
                                .opacity(selected == nil || selected == category.id ? 1 : 0.35)
                        }
                        .buttonStyle(.plain)
                        .frame(width: max(3, geometry.size.width * Double(category.bytes ?? 0) / total))
                        .help("\(info.name) · \(Format.bytes(category.bytes ?? 0))")
                        .accessibilityLabel("\(info.name) \(Format.bytes(category.bytes ?? 0))")
                    }
                    Rectangle().fill(Theme.hairline)
                }
            }
            .frame(height: 26)
            .clipShape(.rect(cornerRadius: 8, style: .continuous))

            FlowLayout(spacing: 6) {
                ForEach(overview.categories) { category in
                    let info = Self.info(category.id)
                    Button { selected = selected == category.id ? nil : category.id } label: {
                        HStack(spacing: 6) {
                            Circle().fill(info.color).frame(width: 9, height: 9)
                            Text(info.name).font(.system(size: 12))
                            Text(category.bytes.map(Format.bytes) ?? (category.note ?? "—"))
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(category.bytes == nil ? Theme.muted : .primary)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 28)
                        .background(selected == category.id ? Theme.raised : .clear, in: .capsule)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected == category.id ? .isSelected : [])
                }
                HStack(spacing: 6) {
                    Circle().strokeBorder(Theme.muted).frame(width: 9, height: 9)
                    Text("Libre").font(.system(size: 12))
                    Text(Format.bytes(overview.available)).font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
            }

            if let current { selectionDetail(current, overview: overview) }
            if current?.id == .other { othersDetail(overview) }

            if !model.preferences.allowPersonalFolders {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised").foregroundStyle(Theme.muted)
                    Text(String(localized: "Documents, Bureau et Téléchargements ne sont pas mesurés : macOS demande votre autorisation pour les lire."))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button(String(localized: "Inclure ces dossiers…")) { model.allowPersonalFolders() }
                        .buttonStyle(PillButtonStyle(kind: .small))
                }
            }
        }
        .padding(20)
        .cardBackground()
    }

    private func selectionDetail(_ category: DiskCategory, overview: DiskOverview) -> some View {
        let info = Self.info(category.id)
        let share = category.bytes.map { Int((Double($0) / Double(max(overview.total, 1)) * 100).rounded()) }
        let recoverable = recoverable(for: category.id)
        return HStack(spacing: 12) {
            Circle().fill(info.color).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(info.name) · \(category.bytes.map(Format.bytes) ?? (category.note ?? "inconnu"))" + (share.map { String(localized: " (\($0) % du disque)") } ?? ""))
                    .font(.system(size: 14, weight: .semibold))
                Text(category.id == .other && category.note != nil ? info.description + " " + category.note! + "."
                     : category.id == .other && overview.localSnapshots > 0
                     ? info.description + (overview.localSnapshots > 1 ? String(localized: " \(overview.localSnapshots) instantanés Time Machine localaux.") : String(localized: " \(overview.localSnapshots) instantané Time Machine local."))
                     : info.description)
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if recoverable > 0 {
                Text("\(Format.bytes(recoverable)) récupérables").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tag.green.0)
            }
            Button(info.action) { model.selection = info.page }
                .buttonStyle(PillButtonStyle(kind: .small))
        }
        .padding(12)
        .background(Theme.raised.opacity(0.6), in: .rect(cornerRadius: 14, style: .continuous))
    }

    /// Détail de « Autres » : chaque dossier mesuré, et ce qui ne peut pas l'être.
    private func othersDetail(_ overview: DiskOverview) -> some View {
        let maxBytes = max(1, overview.others.compactMap(\.bytes).max() ?? 1)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Ce que contient « Autres »").font(.system(size: 14, weight: .semibold)).padding(.bottom, 8)
            ForEach(overview.others) { part in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(part.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(part.note).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let bytes = part.bytes {
                        Capsule().fill(Theme.hairline).frame(width: 140, height: 6)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color(hex: 0xC9B88A)).frame(width: max(3, 140 * Double(bytes) / Double(maxBytes)), height: 6)
                            }
                        Text(Format.bytes(bytes)).font(.system(size: 13, weight: .semibold)).monospacedDigit().frame(width: 80, alignment: .trailing)
                    } else {
                        Text("non mesuré").font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 232, alignment: .trailing)
                    }
                    if let url = part.url, part.bytes != nil {
                        Button(String(localized: "Explorer")) {
                            model.explorer.reveal(url)
                            model.selection = .explorateur
                        }
                        .buttonStyle(PillButtonStyle(kind: .small))
                    } else {
                        Color.clear.frame(width: 84, height: 1)
                    }
                }
                .padding(.vertical, 7)
                Divider().opacity(0.5)
            }
        }
        .padding(14)
        .background(Theme.raised.opacity(0.45), in: .rect(cornerRadius: 14, style: .continuous))
    }

    // MARK: Récupérable

    private func selectedBytes(_ store: ScanStore) -> Int64 {
        store.items.filter { $0.selectedByDefault && !$0.isLocked }.reduce(0) { $0 + $1.bytes }
    }

    private var dockerBytes: Int64 {
        guard let report = model.docker.value else { return 0 }
        return DockerScanner.groups(report, docker: model.dockerPath).flatMap(\.items)
            .filter { $0.selectedByDefault && !$0.isLocked }.reduce(0) { $0 + $1.bytes }
    }

    private func recoverable(for id: DiskCategory.ID) -> Int64 {
        switch id {
        case .sysdata: selectedBytes(model.systemScan)
        case .apps: selectedBytes(model.leftoverScan)
        case .dev: selectedBytes(model.devScan) + selectedBytes(model.cacheScan) + dockerBytes
        default: 0
        }
    }

    /// Lignes sans risque cochées par défaut dans les écrans déjà analysés (hors Docker : pas de corbeille).
    private var safeItems: [CleanupItem] {
        [model.systemScan, model.devScan, model.cacheScan, model.leftoverScan]
            .filter { $0.finishedAt != nil && !$0.stale }
            .flatMap(\.items)
            .filter { $0.selectedByDefault && !$0.isLocked && $0.risk == .safe && $0.action != .emptyTrash }
    }

    private func cleanSafe() {
        if let plan = CleanupPlanner.plan(title: String(localized: "Nettoyer le sans-risque"), items: safeItems,
                                          summary: String(localized: "Caches, artefacts de build et restes d’apps marqués « sans risque » dans chaque écran. Les fichiers vont à la corbeille ; les caches d’outils sont vidés par leur commande officielle.")) {
            model.preview(plan)
        }
    }

    private var recoverableCards: some View {
        let cards: [(String, String, Int64?, String, Page, Risk)] = [
            (String(localized: "Système"), "desktopcomputer", model.systemScan.finishedAt == nil ? nil : selectedBytes(model.systemScan), String(localized: "Caches, logs, corbeille"), .systeme, .safe),
            (String(localized: "Développement"), "chevron.left.forwardslash.chevron.right", model.devScan.finishedAt == nil ? nil : selectedBytes(model.devScan),
             model.devScan.finishedAt == nil ? String(localized: "Analyse au premier passage") : "\(model.devScan.items.count) artefacts", .dev, .safe),
            ("Docker", "shippingbox", model.docker.value?.state == .ready ? dockerBytes : nil, dockerNote, .docker, .caution),
            (String(localized: "Caches de paquets"), "cylinder", model.cacheScan.finishedAt == nil ? nil : selectedBytes(model.cacheScan), "npm, pnpm, Go, Cargo, Xcode", .caches, .safe),
            (String(localized: "Restes d’applications"), "app.dashed", model.leftoverScan.finishedAt == nil ? nil : selectedBytes(model.leftoverScan),
             String(localized: "\(model.leftoverScan.items.count) éléments"), .appsNettoyage, .caution),
        ]
        let sum = max(1, cards.compactMap(\.2).reduce(0, +))
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
            ForEach(cards, id: \.0) { card in
                Button { model.selection = card.4 } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: card.1).foregroundStyle(Theme.accent)
                            Text(card.0).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        }
                        HStack(alignment: .firstTextBaseline) {
                            Text(card.2.map(Format.bytes) ?? "—").font(.system(size: 22, weight: .bold)).monospacedDigit()
                            Spacer(minLength: 4)
                            RiskBadge(risk: card.5).fixedSize()
                        }
                        Text(card.3).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                        GeometryReader { geometry in
                            Capsule().fill(Theme.hairline)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Theme.accent).frame(width: geometry.size.width * Double(card.2 ?? 0) / Double(sum))
                                }
                        }
                        .frame(height: 5)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardBackground(radius: 18)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var dockerNote: String {
        guard let report = model.docker.value else { return "—" }
        switch report.state {
        case .notInstalled: return String(localized: "Docker n’est pas installé")
        case .notRunning: return String(localized: "Docker n’est pas démarré")
        case .ready:
            let data = report.volumes.filter { $0.links == 0 && DockerVolumeKind.classify($0) == .data }.count
            return data > 0 ? (data > 1 ? String(localized: "dont \(data) volumes de données exclus") : String(localized: "dont \(data) volume de données exclus")) : String(localized: "images, volumes, build cache")
        }
    }

    private var progress: some View {
        let rows: [(String, Bool, Bool)] = [
            (String(localized: "Disque"), model.overview.loading, model.overview.value != nil),
            (String(localized: "Système"), model.systemScan.scanning, model.systemScan.finishedAt != nil),
            (String(localized: "Développement"), model.devScan.scanning, model.devScan.finishedAt != nil),
            ("Caches", model.cacheScan.scanning, model.cacheScan.finishedAt != nil),
            (String(localized: "Restes d’apps"), model.leftoverScan.scanning, model.leftoverScan.finishedAt != nil),
            ("Docker", model.docker.loading, model.docker.value != nil),
        ]
        return HStack(spacing: 14) {
            ForEach(rows, id: \.0) { row in
                HStack(spacing: 6) {
                    if row.1 { ProgressView().controlSize(.mini) } else {
                        Image(systemName: row.2 ? "checkmark.circle.fill" : "circle").foregroundStyle(row.2 ? Tag.green.0 : Theme.muted)
                    }
                    Text(row.0).font(.system(size: 12))
                }
            }
            Spacer()
            Text("Rien n’est supprimé pendant l’analyse").font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .cardBackground(radius: 16)
    }

    private var recentDeletions: some View {
        let entries = model.history.filter { $0.kind == .nettoyage }.prefix(4)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Dernières suppressions").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(String(localized: "Tout l’historique →")) { model.selection = .historique }.buttonStyle(.link)
            }
            if entries.isEmpty {
                Text("Aucune suppression pour l’instant.").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            ForEach(Array(entries)) { entry in
                HStack(spacing: 12) {
                    Text(entry.date.formatted(.dateTime.day().month(.abbreviated).hour().minute())).frame(width: 120, alignment: .leading)
                    Text(entry.title).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    Text(entry.bytesFreed.map(Format.bytes) ?? "—").fontWeight(.semibold).frame(width: 80, alignment: .trailing)
                    Text(outcomeLabel(entry.outcome)).foregroundStyle(Theme.muted).frame(width: 150, alignment: .trailing)
                }
                .font(.system(size: 13))
            }
        }
        .padding(18)
        .cardBackground()
    }

    private func outcomeLabel(_ outcome: HistoryEntry.Outcome) -> String {
        switch outcome {
        case .success: String(localized: "Terminé")
        case .partial: String(localized: "Partiel")
        case .failure: String(localized: "Échec")
        case .cancelled: String(localized: "Annulé")
        }
    }
}
