import AppKit
import LAtelierCore
import QuickLook
import SwiftUI

/// Stockage › Sonar : trier ses gros fichiers personnels. Distance au centre = ancienneté, taille du point = poids.
/// Rien ne part sans l'aperçu, et seulement vers la corbeille.
struct SonarPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var preview: URL?

    static func color(_ kind: SonarFile.Kind) -> Color {
        switch kind {
        case .video: Color(hex: 0xB42318)
        case .image: Color(hex: 0xD6336C)
        case .audio: Color(hex: 0x1E8A45)
        case .archive: Color(hex: 0xE8890C)
        case .installer: Color(hex: 0x00879E)
        case .document: Color(hex: 0x6E4BD8)
        case .vm: Color(hex: 0x3A3A40)
        }
    }

    var body: some View {
        let sonar = model.sonar
        PageScaffold(title: "Sonar", subtitle: String(localized: "Plus un point est loin du centre, plus le fichier est vieux. Plus il est gros, plus il pèse.")) {
            gauge(sonar)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                zones(sonar)
                HStack(spacing: 12) {
                    GlassSegments(selection: Binding(get: { sonar.lens }, set: { sonar.lens = $0; sonar.selected = nil }),
                                  items: SonarLens.allCases.map { ($0, $0.label) }, compact: true)
                        .fixedSize()
                    Spacer()
                    Text("Fichiers de plus de").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    GlassSegments(selection: Binding(get: { sonar.minimumBytes }, set: { value in
                        sonar.minimumBytes = value
                        if sonar.scannedZone != nil { scan(sonar.zone) }
                    }), items: [(Int64(10_000_000), String(localized: "10 Mo")), (Int64(50_000_000), String(localized: "50 Mo")), (Int64(100_000_000), String(localized: "100 Mo")), (Int64(500_000_000), String(localized: "500 Mo"))], compact: true)
                        .fixedSize()
                }
            }
            if sonar.scannedZone == nil && !sonar.scanning {
                start(sonar)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 10) {
                        RadarView(files: sonar.live, selected: sonar.current?.id, scanning: sonar.scanning) { sonar.selected = $0 }
                            .frame(maxWidth: 560, maxHeight: 560)
                            .aspectRatio(1, contentMode: .fit)
                        legend
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .cardBackground()
                    aside(sonar)
                        .frame(width: 320)
                }
            }
        }
        .quickLookPreview($preview)
        .onAppear {
            if sonar.scannedZone == nil, !sonar.scanning, ProcessInfo.processInfo.environment["LATELIER_SONAR_HOME"] != nil { scan(.home) }
        }
    }

    private func scan(_ zone: SonarZone) {
        let apps = Set(AppInventory.installed().map { $0.name.lowercased() })
        model.sonar.scan(zone, allowPersonal: model.preferences.allowPersonalFolders, excluded: model.projectRoots + model.excludedFolders, installedApps: apps)
    }

    private func gauge(_ sonar: SonarStore) -> some View {
        let freed = sonar.freed
        let staged = sonar.staged.reduce(0) { $0 + $1.bytes }
        let progress = min(1, Double(freed + staged) / Double(sonar.goal))
        return VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                Text(Format.bytes(freed)).font(.system(size: 15, weight: .bold))
                Text("libérés").font(.system(size: 13))
                if staged > 0 { Text("· \(Format.bytes(staged)) en attente").font(.system(size: 13)).foregroundStyle(Theme.orange) }
                Text("· objectif").font(.system(size: 13)).foregroundStyle(Theme.muted)
                Menu(Format.bytes(sonar.goal)) {
                    ForEach([5, 10, 20, 50], id: \.self) { gb in Button("\(gb) Go") { sonar.goal = Int64(gb) * 1_000_000_000 } }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            ProgressView(value: progress).frame(width: 260).tint(Tag.green.0)
            Text((sonar.sortedCount > 1 ? String(localized: "\(sonar.sortedCount) fichiers triés") : String(localized: "\(sonar.sortedCount) fichier trié")))
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }

    private func zones(_ sonar: SonarStore) -> some View {
        let allowed = model.preferences.allowPersonalFolders
        let list: [SonarZone] = [.home, .downloads, .documents, .desktop, .movies, .music, .pictures]
        return HStack(spacing: 4) {
            ForEach(list, id: \.self) { zone in
                let locked = zone.isPersonal && !allowed
                let selected = sonar.zone == zone
                Button {
                    if locked { model.allowPersonalFolders() }
                    scan(zone)
                } label: {
                    HStack(spacing: 4) {
                        if locked { Image(systemName: "lock").font(.system(size: 10)) }
                        Text(zone.label).fixedSize()
                    }
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .padding(.horizontal, 11)
                    .frame(minHeight: 30)
                    .background { if selected { Capsule().fill(Theme.raised).shadow(color: Theme.shadow.opacity(0.15), radius: 3, y: 2) } }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .help(locked ? String(localized: "macOS demandera l’autorisation de lire ce dossier") : String(localized: "Balayer \(zone.label)"))
            }
        }
        .padding(3)
        .background(Theme.cardFill, in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.cardBorder))
    }

    private func start(_ sonar: SonarStore) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Lancer un balayage").font(.system(size: 17, weight: .semibold))
                Text(String(localized: "Le Sonar repère les gros fichiers (50 Mo par défaut) dans la zone choisie, leur dernière ouverture, les doublons exacts et les installeurs déjà utilisés. Vos projets de code sont ignorés (voir Développement)."))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                if !model.preferences.allowPersonalFolders {
                    Text(String(localized: "Bureau, Documents et Téléchargements sont exclus tant que vous ne les incluez pas : macOS demandera alors l’autorisation."))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                HStack {
                    Button(String(localized: "Balayer \(sonar.zone.label.lowercased())")) { scan(sonar.zone) }
                        .buttonStyle(.primary)
                    if !model.preferences.allowPersonalFolders {
                        Button(String(localized: "Inclure Bureau, Documents, Téléchargements…")) {
                            model.allowPersonalFolders()
                            scan(sonar.zone)
                        }
                        .buttonStyle(.secondary)
                    }
                }
            }
        }
    }

    private var legend: some View {
        FlowLayout(spacing: 10) {
            ForEach(SonarFile.Kind.allCases, id: \.self) { kind in
                HStack(spacing: 5) {
                    Circle().fill(Self.color(kind)).frame(width: 9, height: 9)
                    Text(kind.label).font(.system(size: 12))
                }
            }
        }
    }

    @ViewBuilder
    private func aside(_ sonar: SonarStore) -> some View {
        VStack(spacing: 12) {
            if sonar.scanning {
                ScanningCard(label: String(localized: "Balayage de \(sonar.zone.label.lowercased())…"))
            } else if let file = sonar.current {
                fileCard(file, sonar)
            } else {
                VStack(spacing: 6) {
                    Text(Format.bytes(sonar.freed + sonar.staged.reduce(0) { $0 + $1.bytes })).font(.system(size: 26, weight: .bold)).foregroundStyle(Tag.green.0)
                    Text("Zone triée !").font(.system(size: 16, weight: .semibold))
                    Text(sonar.files.isEmpty ? String(localized: "Aucun fichier de plus de \(Format.bytes(sonar.minimumBytes)) ici.") : String(localized: "Tout a été trié dans ce filtre. Essayez un autre filtre ou une autre zone."))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    if sonar.files.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            if !model.preferences.allowPersonalFolders {
                                Text(String(localized: "Vos gros fichiers sont souvent dans Téléchargements ou Documents, que macOS protège."))
                                    .font(.system(size: 11)).padding(.top, 4)
                                Button(String(localized: "Inclure Bureau, Documents, Téléchargements…")) {
                                    model.allowPersonalFolders()
                                    scan(sonar.zone)
                                }
                                .buttonStyle(PillButtonStyle(kind: .small))
                            } else if sonar.minimumBytes > 10_000_000 {
                                Button(String(localized: "Chercher dès 10 Mo")) {
                                    sonar.minimumBytes = 10_000_000
                                    scan(sonar.zone)
                                }
                                .buttonStyle(PillButtonStyle(kind: .small))
                            }
                        }
                        .padding(.top, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .cardBackground()
            }
            bin(sonar)
        }
    }

    private func fileCard(_ file: SonarFile, _ sonar: SonarStore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(file.url.pathExtension.uppercased().prefix(4))
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Self.color(file.kind), in: .rect(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    Text(file.url.deletingLastPathComponent().abbreviatingHome()).font(.system(size: 11).monospaced())
                        .foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                }
            }
            HStack(spacing: 10) {
                fact(String(localized: "Taille"), Format.bytes(file.bytes))
                fact(String(localized: "Dernière ouverture"), file.lastUsed.map { RelativeDate.french($0) } ?? "jamais")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Pourquoi ?").font(.system(size: 12, weight: .semibold))
                Text(file.reason()).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raised.opacity(0.6), in: .rect(cornerRadius: 10, style: .continuous))
            HStack(spacing: 8) {
                Button(String(localized: "Garder")) { sonar.decide(.keep) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .frame(maxWidth: .infinity)
                Button("Corbeille") { sonar.decide(.trash) }
                    .buttonStyle(.primary(tint: Theme.red))
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: 6) {
                Button(String(localized: "Coup d’œil")) { preview = file.url }.buttonStyle(PillButtonStyle(kind: .small))
                Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }.buttonStyle(PillButtonStyle(kind: .small))
                Spacer()
                Button("Passer →") { sonar.decide(.skip) }.buttonStyle(.plain).font(.system(size: 13, weight: .medium))
            }
        }
        .padding(16)
        .cardBackground()
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 15, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bin(_ sonar: SonarStore) -> some View {
        let staged = sonar.staged
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pour la corbeille (\(staged.count))").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !sonar.decisions.isEmpty {
                    Button("Annuler la dernière") { sonar.undo() }.buttonStyle(.link).font(.system(size: 12))
                }
            }
            ForEach(staged.suffix(5).reversed()) { file in
                HStack {
                    Text(file.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Format.bytes(file.bytes)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                }
            }
            if staged.count > 5 { Text("et \(staged.count - 5) autres").font(.system(size: 12)).foregroundStyle(Theme.muted) }
            Button((staged.count > 1 ? String(localized: "Mettre \(staged.count) fichiers à la corbeille…") : String(localized: "Mettre \(staged.count) fichier à la corbeille…"))) {
                if let plan = sonar.trashPlan { model.preview(plan) }
            }
            .buttonStyle(PillButtonStyle(kind: .smallFilled))
            .disabled(staged.isEmpty)
            Text(String(localized: "Rien n’est supprimé définitivement : tout part dans la corbeille de macOS, après l’aperçu."))
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .padding(16)
        .cardBackground()
    }
}

/// Radar : anneaux d'ancienneté, balayage animé, un point par fichier.
private struct RadarView: View {
    let files: [SonarFile]
    let selected: String?
    let scanning: Bool
    let pick: (String) -> Void

    private static let rings: [(days: Int, label: String)] = [(30, String(localized: "1 mois")), (180, String(localized: "6 mois")), (365, String(localized: "1 an")), (1095, String(localized: "3 ans"))]

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let radius = size / 2
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            // Placement calculé une fois (pas à chaque image de l'animation).
            let blips = placed(radius: radius)
            TimelineView(.periodic(from: .now, by: 1.0 / 20)) { context in
                let sweep = (context.date.timeIntervalSinceReferenceDate * (scanning ? 180 : 60)).truncatingRemainder(dividingBy: 360)
                ZStack {
                    Circle().fill(Color(hex: 0x0E2A3A).opacity(0.9)).frame(width: size, height: size)
                    ForEach(Self.rings, id: \.days) { ring in
                        let r = SonarRadar.radius(ageDays: ring.days) * radius
                        Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1).frame(width: r * 2, height: r * 2)
                        Text(ring.label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                            .position(x: center.x + 4, y: center.y - r + 8)
                    }
                    // Faisceau du balayage.
                    Path { path in
                        path.move(to: CGPoint(x: radius, y: radius))
                        path.addArc(center: CGPoint(x: radius, y: radius), radius: radius, startAngle: .degrees(-40), endAngle: .degrees(0), clockwise: false)
                        path.closeSubpath()
                    }
                    .fill(AngularGradient(colors: [Color(hex: 0x34C759).opacity(0), Color(hex: 0x34C759).opacity(0.45)],
                                          center: .center, startAngle: .degrees(-40), endAngle: .degrees(0)))
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(sweep - 90))
                    ForEach(blips, id: \.file.id) { blip in
                        let diff = ((sweep - blip.angle).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
                        let ping = diff < 40
                        let isSelected = blip.file.id == selected
                        let rad = (blip.angle - 90) * .pi / 180
                        Button { pick(blip.file.id) } label: {
                            Circle()
                                .fill(SonarPage.color(blip.file.kind))
                                .overlay(Circle().strokeBorder(isSelected ? Color.white : Color.white.opacity(0.8), lineWidth: isSelected ? 3 : 1.5))
                                .shadow(color: ping ? SonarPage.color(blip.file.kind) : .black.opacity(0.3), radius: ping ? 8 : 2)
                                .frame(width: blip.diameter, height: blip.diameter)
                                .scaleEffect(isSelected ? 1.25 : ping ? 1.1 : 1)
                                .opacity(ping || isSelected ? 1 : 0.8)
                        }
                        .buttonStyle(.plain)
                        .position(x: center.x + cos(rad) * blip.distance * radius, y: center.y + sin(rad) * blip.distance * radius)
                        .help("\(blip.file.name) · \(Format.bytes(blip.file.bytes))")
                        .accessibilityLabel(String(localized: "\(blip.file.name), \(Format.bytes(blip.file.bytes)), ouvert \(blip.file.lastUsed.map { RelativeDate.french($0) } ?? "jamais")"))
                    }
                    Circle().fill(Color.white.opacity(0.9)).frame(width: 6, height: 6)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    private struct Blip {
        var file: SonarFile
        var angle: Double
        var distance: Double
        var diameter: Double
    }

    /// Positions sans chevauchement : chaque point (du plus gros au plus petit) prend la place libre
    /// la plus proche de sa position idéale, dans le secteur de son type et près de son anneau d'ancienneté.
    private func placed(radius: Double) -> [Blip] {
        var slots: [SonarFile.Kind: Int] = [:]
        var result: [Blip] = []
        var taken: [(x: Double, y: Double, r: Double)] = []
        let sector = 360.0 / Double(SonarFile.Kind.allCases.count)
        for file in files.sorted(by: { $0.bytes > $1.bytes }).prefix(120) {
            let slot = slots[file.kind, default: 0]
            slots[file.kind] = slot + 1
            let gb = Double(file.bytes) / 1_000_000_000
            let diameter = min(46, 12 + sqrt(gb) * 10)
            let idealAngle = SonarRadar.angle(kind: file.kind, slot: slot)
            let idealDistance = SonarRadar.radius(ageDays: file.ageDays())
            let start = Double(SonarFile.Kind.allCases.firstIndex(of: file.kind) ?? 0) * sector
            func point(_ angle: Double, _ distance: Double) -> (Double, Double) {
                let rad = (angle - 90) * .pi / 180
                return (cos(rad) * distance * radius, sin(rad) * distance * radius)
            }
            func free(_ angle: Double, _ distance: Double) -> Bool {
                let (x, y) = point(angle, distance)
                return !taken.contains { hypot($0.x - x, $0.y - y) < $0.r + diameter / 2 + 2 }
            }
            var best = (angle: idealAngle, distance: idealDistance)
            if !free(idealAngle, idealDistance) {
                var found = false
                // Cercles de recherche autour de la position idéale : d'abord l'angle, puis un peu la distance.
                search: for step in 1...60 {
                    for (dAngle, dDistance) in [(Double(step) * 1.5, 0.0), (-Double(step) * 1.5, 0.0),
                                                (Double(step), 0.015 * Double(step)), (-Double(step), -0.015 * Double(step)),
                                                (0.0, 0.02 * Double(step)), (0.0, -0.02 * Double(step))] {
                        let angle = idealAngle + dAngle
                        let distance = idealDistance + dDistance
                        guard angle >= start + 2, angle <= start + sector - 2, distance >= 0.1, distance <= 0.97 else { continue }
                        if free(angle, distance) {
                            best = (angle, distance)
                            found = true
                            break search
                        }
                    }
                }
                if !found { best = (idealAngle, idealDistance) }
            }
            let (x, y) = point(best.angle, best.distance)
            taken.append((x, y, diameter / 2))
            result.append(Blip(file: file, angle: best.angle, distance: best.distance, diameter: diameter))
        }
        return result
    }
}
