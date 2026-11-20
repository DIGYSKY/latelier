import AppKit
import LAtelierCore
import SwiftUI

// Style de la maquette (claude.ai/artifact/5YTXSVHCstH3VuKr9HzvGP) : fond dégradé vif,
// fenêtre en verre blanc, cartes blanches translucides, boutons capsule.

enum Theme {
    static let accent = Color(hex: 0x0A6CDB)
    static let red = Color(hex: 0xB42318)
    static let orange = Color(hex: 0x9A4F00)
    static let muted = Color.adaptive(light: NSColor(hex: 0x4F4F56), dark: NSColor(white: 0.68, alpha: 1))

    /// Remplissage des cartes : blanc à 62 % en clair.
    static let cardFill = Color.adaptive(light: NSColor(white: 1, alpha: 0.62), dark: NSColor(white: 1, alpha: 0.07))
    static let cardBorder = Color.adaptive(light: NSColor(white: 1, alpha: 0.85), dark: NSColor(white: 1, alpha: 0.12))
    /// Pastille active, boutons secondaires.
    static let raised = Color.adaptive(light: NSColor(white: 1, alpha: 0.9), dark: NSColor(white: 1, alpha: 0.14))
    static let hairline = Color.adaptive(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.1))
    static let shadow = Color(red: 30 / 255, green: 40 / 255, blue: 90 / 255)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Fond de fenêtre : dégradé vif, voilé de blanc pour l'effet verre.
struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme
    /// Réglages › Général › Transparence : « reduced », « normal », « max ».
    var glass = "normal"

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            Color(hex: dark ? 0x1B2350 : 0x5B74E8)
            RadialGradient(colors: [Color(hex: 0x8EC5FF), .clear], center: UnitPoint(x: 0.08, y: 0), startRadius: 0, endRadius: 700)
            RadialGradient(colors: [Color(hex: 0xC7A4FF), .clear], center: UnitPoint(x: 0.95, y: 0.15), startRadius: 0, endRadius: 620)
            RadialGradient(colors: [Color(hex: 0x6FE0CF), .clear], center: UnitPoint(x: 0.55, y: 1.05), startRadius: 0, endRadius: 760)
            let wash = glass == "reduced" ? 0.22 : glass == "max" ? -0.25 : 0
            (dark ? Color.black.opacity(0.62 + wash) : Color.white.opacity(0.55 + wash))
        }
        .ignoresSafeArea()
    }
}

/// Mise en page commune : en-tête, défilement, marges de la maquette.
/// Projet auquel un écran est limité quand il est affiché dans la page d'un dépôt.
private struct ProjectScopeKey: EnvironmentKey {
    static let defaultValue: URL? = nil
}

extension EnvironmentValues {
    var projectScope: URL? {
        get { self[ProjectScopeKey.self] }
        set { self[ProjectScopeKey.self] = newValue }
    }
}

struct PageScaffold<Actions: View, Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content
    @Environment(\.projectScope) private var scope

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if scope == nil {
                    PageHeader(title: title, subtitle: subtitle) { actions }
                } else {
                    // Dans la page d'un dépôt : pas de grand titre, les actions restent.
                    HStack(spacing: 10) {
                        if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(2) }
                        Spacer()
                        actions
                    }
                }
                content
            }
            .padding(.leading, 22)
            .padding(.trailing, 30)
            .padding(.top, 6)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }
}

extension PageScaffold where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, actions: { EmptyView() }, content: content)
    }
}

extension PageScaffold {
    init(page: Page, subtitle: String? = nil, @ViewBuilder actions: () -> Actions, @ViewBuilder content: () -> Content) {
        self.init(title: page.headerTitle, subtitle: subtitle, actions: actions, content: content)
    }
}

extension PageScaffold where Actions == EmptyView {
    init(page: Page, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: page.headerTitle, subtitle: subtitle, actions: { EmptyView() }, content: content)
    }
}

struct PageHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.4)
                if let subtitle {
                    Text(subtitle).font(.system(size: 14)).foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 16)
            HStack(spacing: 10) { actions }
        }
    }
}

/// Carte blanche translucide de la maquette.
struct Card<Content: View>: View {
    var title: String?
    var trailing: String?
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || trailing != nil {
                HStack {
                    if let title { Text(title).font(.system(size: 15, weight: .semibold)) }
                    Spacer()
                    if let trailing { Text(trailing).font(.system(size: 12)).foregroundStyle(Theme.muted) }
                }
            }
            content
        }
        .padding(.horizontal, padding)
        .padding(.vertical, padding - 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

extension View {
    func cardBackground(radius: CGFloat = 22) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.cardFill)
                .overlay(alignment: .top) {
                    // Reflet en haut de la carte.
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0)], startPoint: .top, endPoint: .center), lineWidth: 1)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 1)
                }
                .shadow(color: Theme.shadow.opacity(0.08), radius: 10, y: 6)
        }
    }
}

/// Boutons capsule : principal (bleu plein), secondaire (verre blanc), petit (dans les listes).
struct PillButtonStyle: ButtonStyle {
    /// `smallFilled` : taille des listes, mais plein comme le principal (« Mettre à jour vers… »).
    enum Kind { case primary, secondary, small, smallFilled }
    var kind: Kind
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, kind: kind, tint: tint)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let kind: Kind
        let tint: Color
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let primary = kind == .primary || kind == .smallFilled
            let small = kind == .small || kind == .smallFilled
            configuration.label
                .font(.system(size: small ? 13 : 14, weight: primary ? .semibold : .medium))
                .labelStyle(PillLabelStyle())
                .foregroundStyle(primary ? Color.white : Color.primary)
                .padding(.horizontal, small ? 14 : primary ? 22 : 18)
                .frame(minHeight: small ? 34 : 44)
                .background {
                    Capsule()
                        .fill(primary ? AnyShapeStyle(tint) : AnyShapeStyle(small ? Theme.raised : Theme.cardFill))
                        .overlay {
                            Capsule().strokeBorder(primary ? Color.white.opacity(0.25) : (small ? Theme.hairline : Theme.cardBorder), lineWidth: 1)
                        }
                        .shadow(
                            color: primary ? tint.opacity(0.35) : Theme.shadow.opacity(small ? 0 : 0.10),
                            radius: primary ? 8 : 6, y: primary ? 6 : 4
                        )
                }
                .contentShape(Capsule())
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.snappy(duration: 0.15), value: configuration.isPressed)
        }
    }
}

private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.font(.system(size: 14, weight: .medium))
            configuration.title
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var primary: PillButtonStyle { PillButtonStyle(kind: .primary) }
    static var secondary: PillButtonStyle { PillButtonStyle(kind: .secondary) }
    static var small: PillButtonStyle { PillButtonStyle(kind: .small) }
    static func primary(tint: Color) -> PillButtonStyle { PillButtonStyle(kind: .primary, tint: tint) }
}

/// Badge de risque, le même partout.
struct RiskBadge: View {
    let risk: Risk

    var body: some View {
        Label(risk.label, systemImage: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.13), in: .capsule)
    }

    var color: Color {
        switch risk {
        case .safe: Color(hex: 0x1E7B34)
        case .caution: Theme.orange
        case .danger: Theme.red
        case .protected: Theme.muted
        }
    }

    private var symbol: String {
        switch risk {
        case .safe: "checkmark.shield"
        case .caution: "exclamationmark.triangle"
        case .danger: "xmark.octagon"
        case .protected: "lock"
        }
    }
}

/// État vide : icône, phrase.
struct EmptyState: View {
    let symbol: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(Theme.muted.opacity(0.6))
            Text(title).font(.system(size: 14, weight: .semibold))
            if let message {
                Text(message).font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

/// Pastille d'icône blanche (tuiles, lignes).
struct IconChip: View {
    let symbol: String
    var color: Color = .primary
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(Theme.raised, in: .rect(cornerRadius: size * 0.31, style: .continuous))
            .shadow(color: Theme.shadow.opacity(0.1), radius: 3, y: 2)
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        value == 0 ? "0 octet" : ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int(seconds * 1000)) ms" : seconds.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "fr_FR"))) + " s"
    }
}
