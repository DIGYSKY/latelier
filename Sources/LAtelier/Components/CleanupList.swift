import LAtelierCore
import SwiftUI

/// Liste de nettoyage de la maquette (ListPanel) : groupes en cartes, lignes à cocher,
/// badge de risque, taille ; barre flottante avec le total et « Vérifier et nettoyer… ».
struct CleanupList: View {
    let groups: [CleanupGroup]
    @Binding var selection: Set<String>

    var body: some View {
        VStack(spacing: 14) {
            ForEach(groups) { group in
                GroupCard(group: group, selection: $selection)
            }
        }
    }
}

private struct GroupCard: View {
    let group: CleanupGroup
    @Binding var selection: Set<String>

    var body: some View {
        let selectable = group.items.filter { !$0.isLocked }
        let allOn = !selectable.isEmpty && selectable.allSatisfy { selection.contains($0.id) }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(group.tone == .data ? Theme.red : group.tone == .neutral ? Color.primary.opacity(0.8) : .primary)
                    if let detail = group.detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                if selectable.count > 1 {
                    Button(allOn ? "Tout décocher" : "Tout cocher") {
                        let ids = selectable.map(\.id)
                        if allOn { selection.subtract(ids) } else { selection.formUnion(ids) }
                    }
                    .buttonStyle(PillButtonStyle(kind: .small))
                    .controlSize(.small)
                }
                Text(group.bytes > 0 ? Format.bytes(group.bytes) : "—")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 72, alignment: .trailing)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.white.opacity(group.tone == .normal ? 0.45 : 0.3))

            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                Rectangle().fill(Theme.hairline).frame(height: 1)
                CleanupRow(item: item, selected: selection.contains(item.id)) {
                    if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
                }
            }
        }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .cardBackground()
    }
}

private struct CleanupRow: View {
    let item: CleanupItem
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isLocked ? "lock.fill" : selected ? "checkmark.square.fill" : "square")
                .font(.system(size: item.isLocked ? 12 : 17))
                .foregroundStyle(item.isLocked ? Theme.muted : selected ? Theme.accent : Theme.muted)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(item.isLocked ? Theme.muted : .primary)
                    if let tag = item.tag {
                        Text(tag)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(hex: 0x0A5BBF))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.12), in: .capsule)
                    }
                }
                Text(item.detail)
                    .font(item.detailIsPath ? .system(size: 12).monospaced() : .system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.meta ?? "")
                .font(.system(size: 13, weight: item.metaHighlighted ? .semibold : .regular))
                .foregroundStyle(item.metaHighlighted ? Theme.orange : Color.primary.opacity(0.75))
                .frame(width: 130, alignment: .leading)
            RiskBadge(risk: item.risk)
                .frame(width: 110, alignment: .leading)
            Text(item.bytes > 0 ? Format.bytes(item.bytes) : "—")
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(item.isLocked ? Theme.muted : .primary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .background(selected && !item.isLocked ? Theme.accent.opacity(0.06) : .clear)
        .contentShape(.rect)
        .onTapGesture { if !item.isLocked { toggle() } }
        .help(item.lockReason.map { "Verrouillé : \($0)" } ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(item.isLocked ? "verrouillé" : selected ? "coché" : "non coché")
    }
}

/// Barre flottante du bas : total sélectionné et action.
struct CleanupBar: View {
    let count: Int
    let bytes: Int64
    var verb = "à mettre à la corbeille"
    let clear: () -> Void
    let review: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            (Text("\(count) élément\(count > 1 ? "s" : "")").bold()
                + Text(" · \(Format.bytes(bytes)) \(verb)").foregroundStyle(Theme.muted))
                .font(.system(size: 14))
            Spacer()
            Button("Tout désélectionner", action: clear)
                .buttonStyle(.secondary)
                .disabled(count == 0)
            Button("Vérifier et nettoyer…", action: review)
                .buttonStyle(.primary)
                .disabled(count == 0)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.leading, 22)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background {
            Capsule().fill(.regularMaterial)
                .overlay(Capsule().fill(Color.white.opacity(0.35)))
                .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: 1))
                .shadow(color: Theme.shadow.opacity(0.22), radius: 16, y: 12)
        }
        .padding(.leading, 22)
        .padding(.trailing, 30)
        .padding(.bottom, 14)
    }
}

/// Carte « analyse en cours ».
struct ScanningCard: View {
    let label: String

    var body: some View {
        Card {
            HStack(spacing: 14) {
                ProgressView().controlSize(.small)
                Text(label).font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
    }
}

extension ScanStore {
    /// « Dernière analyse : à 11:02 · 2,1 s ».
    var statusLine: String? {
        guard let finishedAt else { return nil }
        let time = finishedAt.formatted(date: .omitted, time: .shortened)
        return "Dernière analyse à \(time) · \(Format.duration(duration))"
    }
}
