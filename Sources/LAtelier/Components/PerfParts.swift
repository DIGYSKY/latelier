import AppKit
import LAtelierCore
import SwiftUI

extension Format {
    private static let french = Locale.current

    /// « 2,4 Mo/s », « 180 Ko/s ».
    static func rate(_ bytesPerSecond: Double) -> String {
        let ko = bytesPerSecond / 1000
        if ko < 1 { return bytesPerSecond < 1 ? String(localized: "0 Ko/s") : String(localized: "< 1 Ko/s") }
        if ko < 1000 { return "\(Int(ko.rounded())) Ko/s" }
        let mo = ko / 1000
        if mo < 1000 { return decimal(mo, decimals: mo < 100 ? 1 : 0) + " Mo/s" }
        return decimal(mo / 1000) + " Go/s"
    }

    /// Volume arrondi pour les tuiles (« 60 Go », « 3,2 Go », « 840 Mo »).
    static func total(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1e9
        if gb >= 10 { return "\(Int(gb.rounded())) Go" }
        if gb >= 1 { return decimal(gb) + " Go" }
        return "\(Int((Double(bytes) / 1e6).rounded())) Mo"
    }

    static func percent(_ value: Double, decimals: Int = 0) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)).locale(french)) + " %"
    }

    static func decimal(_ value: Double, decimals: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)).locale(french))
    }

    /// Mémoire en Go avec une décimale (« 18,4 Go »), en Mo en dessous de 1 Go.
    static func memory(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return decimal(gb) + " Go" }
        return "\(bytes >> 20) Mo"
    }
}

/// Courbe glissante (60 s) avec aire, comme dans la maquette.
struct Sparkline: View {
    let values: [Double]
    var maxValue: Double?
    var color: Color = Theme.accent

    var body: some View {
        GeometryReader { geometry in
            let points = Self.points(values, max: maxValue, size: geometry.size)
            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geometry.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points.last!.x, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(color.opacity(0.14))
                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Les points sont calés à droite : l'historique se remplit de droite à gauche au démarrage.
    static func points(_ values: [Double], max: Double?, size: CGSize) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let top = Swift.max(max ?? (values.max() ?? 1) * 1.15, 0.0001)
        let step = size.width / CGFloat(PerformanceMonitor.historyLength - 1)
        let offset = CGFloat(PerformanceMonitor.historyLength - values.count) * step
        return values.enumerated().map { index, value in
            let ratio = Swift.min(1, Swift.max(0, value / top))
            return CGPoint(x: offset + CGFloat(index) * step, y: size.height - CGFloat(ratio) * (size.height - 2) - 1)
        }
    }
}

/// Tuile de ressource : libellé, valeur, détail, courbe.
struct MetricTile: View {
    let label: String
    let value: String
    let detail: String
    var detailColor: Color = Theme.muted
    var detailBold = false
    let history: [Double]
    var maxValue: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 22, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(detail)
                .font(.system(size: 12, weight: detailBold ? .semibold : .regular))
                .foregroundStyle(detailColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Sparkline(values: history, maxValue: maxValue)
                .frame(height: 40)
                .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(radius: 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) : \(value), \(detail)")
    }
}

/// Petite tuile de chiffre (Réseau) : libellé et valeur.
struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 22, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(radius: 18)
        .accessibilityElement(children: .combine)
    }
}

/// Icône d'un processus : celle de son app, sinon une pastille avec l'initiale.
struct ProcessIcon: View {
    let name: String
    let bundle: String?
    var dimmed = false

    private static var cache: [String: NSImage] = [:]

    var body: some View {
        Group {
            if let bundle, let image = Self.icon(bundle) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Self.color(for: name).opacity(dimmed ? 0.45 : 1), in: .rect(cornerRadius: 6, style: .continuous))
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    private static func icon(_ bundle: String) -> NSImage? {
        if let cached = cache[bundle] { return cached }
        guard FileManager.default.fileExists(atPath: bundle) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: bundle)
        cache[bundle] = image
        return image
    }

    /// Couleur stable par nom (node vert, python bleu…).
    static func color(for name: String) -> Color {
        let lower = name.lowercased()
        if lower.hasPrefix("node") || lower == "npm" || lower == "vite" { return Color(hex: 0x3C873A) }
        if lower.hasPrefix("python") || lower.hasPrefix("jupyter") { return Color(hex: 0x3776AB) }
        if lower == "java" { return Color(hex: 0xB07219) }
        if lower.contains("docker") { return Color(hex: 0x1D63ED) }
        if lower.hasPrefix("postgres") { return Color(hex: 0x336791) }
        if lower.hasPrefix("redis") { return Color(hex: 0xD82C20) }
        if lower == "ruby" || lower == "puma" { return Color(hex: 0xCC342D) }
        if lower == "go" || lower == "gopls" { return Color(hex: 0x00ADD8) }
        if lower == "cargo" || lower.hasPrefix("rust") { return Color(hex: 0xB7410E) }
        let palette: [UInt32] = [0x6E6E73, 0x5856D6, 0x0A6CDB, 0x0E7C66, 0xAF52DE, 0xC93400, 0x8E8E93]
        let hash = name.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        return Color(hex: palette[Int(hash % UInt32(palette.count))])
    }
}

/// Bouton d'en-tête de colonne triable (« % CPU ▾ »).
struct SortHeader: View {
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label + (active ? " ▾" : ""))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .frame(minHeight: 26)
                .background(active ? Theme.raised : .clear, in: .rect(cornerRadius: 8, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Trier par \(label)"))
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Segments capsule en verre (« Par app | Liste », filtres de la maquette).
struct GlassSegments<ID: Hashable>: View {
    @Binding var selection: ID
    let items: [(id: ID, label: String)]
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let selected = selection == item.id
                Button { selection = item.id } label: {
                    Text(item.label)
                        .font(.system(size: compact ? 12 : 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, compact ? 12 : 16)
                        .frame(minHeight: compact ? 30 : 34)
                        .background {
                            if selected {
                                Capsule().fill(Theme.raised).shadow(color: Theme.shadow.opacity(0.15), radius: 3, y: 2)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(compact ? 3 : 4)
        .background(Theme.cardFill, in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.cardBorder))
    }
}

extension AppModel {
    /// Quitter un processus ou une app, après aperçu.
    func quit(_ targets: [ProcessTarget], label: String, force: Bool, reason: String? = nil) {
        guard let plan = ProcessActions.quitPlan(targets, label: label, force: force, reason: reason) else { return }
        preview(plan)
    }

    /// Nom court d'un projet : « web », ou « front/web » si deux projets portent le même nom.
    func projectName(_ url: URL) -> String {
        let name = url.lastPathComponent
        let twins = knownProjects.filter { $0.lastPathComponent == name }.count
        return twins > 1 ? "\(url.deletingLastPathComponent().lastPathComponent)/\(name)" : name
    }
}

extension RunningProcess {
    /// Nom affiché : le nom de l'app pour son processus principal.
    var displayName: String {
        if target.isApp, let bundle = appBundle, path?.hasPrefix(bundle + "/Contents/MacOS/") == true {
            return ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        // Exécutable nommé par sa version (« ~/.local/share/claude/versions/2.1.328 ») : on prend l'outil.
        if name.first?.isNumber == true, name.allSatisfy({ $0.isNumber || $0 == "." }), let path {
            let parts = path.split(separator: "/").map(String.init)
            if parts.count >= 3, parts[parts.count - 2] == "versions" { return parts[parts.count - 3] }
            if parts.count >= 2 { return parts[parts.count - 2] }
        }
        return name
    }

    var userLabel: String {
        if isMine { return "vous" }
        if uid == 0 { return "root" }
        return uid < 500 ? String(localized: "système") : (getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? "\(uid)")
    }
}
