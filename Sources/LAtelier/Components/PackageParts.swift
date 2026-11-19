import AppKit
import LAtelierCore
import SwiftUI

/// Champ de recherche capsule (en-têtes Paquets).
struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button("Effacer", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .frame(width: 240, height: 40)
        .background(Theme.raised.opacity(0.8), in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.cardBorder))
    }
}

/// Choix de la source : « Tout 238 · Homebrew 142 · npm -g 23… », pastille bleue pleine pour la sélection.
struct SourceChips: View {
    @Binding var selection: PackageSource?
    let counts: [(source: PackageSource?, count: Int)]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(counts, id: \.source) { item in
                let selected = selection == item.source
                Button { selection = item.source } label: {
                    HStack(spacing: 5) {
                        Text(item.source?.label ?? "Tout")
                        Text("\(item.count)").opacity(0.75)
                    }
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
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.cardFill, in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.cardBorder))
    }
}

/// Petite étiquette colorée (écart de version, état).
struct Tag: View {
    let text: String
    var foreground: Color
    var background: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(background, in: .capsule)
            .lineLimit(1)
            .fixedSize()
    }

    static func gap(_ gap: UpdateGap) -> Tag {
        switch gap {
        case .major: Tag(text: gap.label, foreground: red.0, background: red.1)
        case .minor: Tag(text: gap.label, foreground: orange.0, background: orange.1)
        case .patch: Tag(text: gap.label, foreground: blue.0, background: blue.1)
        case .other: Tag(text: gap.label, foreground: grey.0, background: grey.1)
        }
    }

    private static func ink(_ light: UInt32, _ dark: UInt32) -> Color {
        .adaptive(light: NSColor(hex: light), dark: NSColor(hex: dark))
    }

    static let green = (ink(0x145C2A, 0x7EE2A0), Color(hex: 0x34C759).opacity(0.2))
    static let blue = (ink(0x0A4A99, 0x8CC2FF), Color(hex: 0x3D8BFF).opacity(0.18))
    static let red = (ink(0x8E1F14, 0xFF9A90), Color(hex: 0xFF3B30).opacity(0.18))
    static let orange = (ink(0x7A3E00, 0xFFC266), Color(hex: 0xFF9500).opacity(0.2))
    static let grey = (Theme.muted, Color.adaptive(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.1)))
}

/// Étiquette de source en capsule blanche (« Homebrew », « npm -g »).
struct SourceLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Theme.raised, in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .lineLimit(1)
            .fixedSize()
    }
}

/// Bloc de texte sombre, police à chasse fixe (commandes, logs).
struct ConsoleBlock: View {
    let text: String
    var color: Color = Color(hex: 0xE8EAF2)
    var maxHeight: CGFloat? = nil

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 12).monospaced())
                .foregroundStyle(color)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: maxHeight == nil)
        .background(Color(red: 20 / 255, green: 22 / 255, blue: 35 / 255).opacity(0.82), in: .rect(cornerRadius: 18, style: .continuous))
    }
}

extension Package {
    /// Texte de la colonne « Source » : Homebrew, Homebrew · cask…
    var sourceLabel: String { source.label }

    /// Description courte : dépendance, cask…
    var detail: String {
        if !onRequest { return summary.isEmpty ? "Dépendance" : "Dépendance · \(summary)" }
        if isCask { return summary.isEmpty ? "Cask" : "Cask · \(summary)" }
        return summary
    }
}

enum FrenchDate {
    /// « mars 2024 »
    static func monthYear(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).year().locale(Locale(identifier: "fr_FR")))
    }
}
