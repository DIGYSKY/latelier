import LAtelierCore
import SwiftUI

/// Paquets › Runtimes : versions de langages installées, par défaut, fin de vie, projets qui les utilisent.
struct RuntimesPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.runtimes
        PageScaffold(page: .runtimes, subtitle: "Versions de langages installées, version par défaut et fin de vie (endoflife.date)") {
            Button("Actualiser", systemImage: "arrow.clockwise") { model.scanRuntimes() }
                .buttonStyle(.secondary)
                .disabled(store.loading)
        } content: {
            if let languages = store.value, !languages.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 14, alignment: .top)], spacing: 14) {
                    ForEach(languages) { language in
                        LanguageCard(language: language)
                    }
                }
            } else if store.loading || store.value == nil {
                ScanningCard(label: "Recherche des versions de Node, Python, Rust, Java, Go et Swift…")
            } else {
                Card { EmptyState(symbol: "chevron.left.forwardslash.chevron.right", title: "Aucun runtime géré trouvé") }
            }
        }
        .onAppear { if store.stale && !store.loading { model.scanRuntimes() } }
        .onChange(of: store.stale) { _, stale in if stale && !store.loading { model.scanRuntimes() } }
    }
}

private struct LanguageCard: View {
    @Environment(AppModel.self) private var model
    let language: RuntimeLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(language.short)
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(color, in: .rect(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(language.name).font(.system(size: 15, weight: .semibold))
                    Text("via \(language.manager)").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Text(language.bytes > 0 ? Format.bytes(language.bytes) : "—")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }
            VStack(spacing: 6) {
                ForEach(language.versions) { version in
                    VersionRow(language: language, version: version)
                }
            }
            if let suggestion = language.suggestion {
                Button(suggestion.label, systemImage: language.id == "rust" ? "arrow.down.circle" : "plus") {
                    model.preview(ActionPlan(
                        title: "\(language.name) : \(suggestion.label.prefix(1).lowercased() + suggestion.label.dropFirst())",
                        summary: language.id == "rust" ? "rustup télécharge la dernière version stable et remplace l’actuelle." : "Installé à côté des versions existantes ; la version par défaut ne change pas.",
                        kind: .paquet, risk: .safe, reversible: false, commands: [suggestion.command]
                    ))
                }
                .buttonStyle(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private var color: Color {
        switch language.id {
        case "node": Color(hex: 0x3C873A)
        case "python": Color(hex: 0x3776AB)
        case "rust": Color(hex: 0xB7410E)
        case "java": Color(hex: 0xB07219)
        case "go": Color(hex: 0x00ADD8)
        case "swift": Color(hex: 0xF05138)
        default: Theme.accent
        }
    }
}

private struct VersionRow: View {
    @Environment(AppModel.self) private var model
    let language: RuntimeLanguage
    let version: RuntimeVersion

    var body: some View {
        let eol = version.isEndOfLife()
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(version.version).font(.system(size: 13, weight: .semibold).monospaced())
                    if version.isDefault { Tag(text: "Par défaut", foreground: Tag.blue.0, background: Tag.blue.1) }
                    if eol { Tag(text: "Fin de vie", foreground: Tag.red.0, background: Tag.red.1) }
                }
                Text(usage).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !version.isDefault, !eol, let command = version.setDefault {
                Button("Par défaut") {
                    model.preview(ActionPlan(
                        title: "\(language.name) \(version.version) par défaut",
                        summary: "Les nouveaux terminaux utiliseront cette version. Les projets qui fixent leur version ne changent pas.",
                        kind: .paquet, risk: .safe, reversible: true, commands: [command]
                    ))
                }
                .buttonStyle(.small)
            }
            if version.canRemove, let command = version.remove {
                Button("Supprimer") {
                    let size = version.bytes.map { " Libère environ \(Format.bytes($0))." } ?? ""
                    model.preview(ActionPlan(
                        title: "Supprimer \(language.name) \(version.version)",
                        summary: "Aucun projet ne l’utilise et ce n’est pas la version par défaut.\(size)",
                        kind: .paquet, risk: .caution, reversible: false, commands: [command],
                        estimatedBytes: version.bytes
                    ))
                }
                .buttonStyle(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(version.isDefault ? Theme.raised : Theme.cardFill, in: .rect(cornerRadius: 12, style: .continuous))
    }

    private var usage: String {
        var parts: [String] = []
        if version.isSystem { parts.append("Fournie par Xcode") }
        if version.usedBy.isEmpty {
            if !version.isSystem { parts.append("Aucun projet") }
        } else {
            let names = version.usedBy.prefix(3).joined(separator: ", ")
            parts.append("Utilisé par \(names)\(version.usedBy.count > 3 ? " et \(version.usedBy.count - 3) autres" : "")")
        }
        if let eol = version.endOfLife, eol != .distantPast, !version.isEndOfLife() {
            parts.append("support jusqu’en \(FrenchDate.monthYear(eol))")
        }
        if let bytes = version.bytes, bytes > 0 { parts.append(Format.bytes(bytes)) }
        return parts.joined(separator: " · ")
    }
}
