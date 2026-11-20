import AppKit
import LAtelierCore
import SwiftUI

/// Performance › Démarrage : éléments de connexion, agents utilisateur, agents et démons système.
struct StartupPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.startup
        PageScaffold(page: .demarrage, subtitle: subtitle(store.value)) {
            if store.loading { ProgressView().controlSize(.small) }
            Button("Réglages Système") { Self.openLoginSettings() }
                .buttonStyle(.secondary)
                .help("Réglages Système › Général › Ouverture : là où macOS gère les éléments de connexion")
        } content: {
            if let result = store.value {
                ForEach(StartupItem.Kind.allCases, id: \.self) { kind in
                    let items = result.items.filter { $0.kind == kind }.sorted(by: order)
                    if !items.isEmpty { GroupCard(kind: kind, items: items) }
                }
                ForEach(result.problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.orange)
                }
                Text("Impact estimé d’après la façon dont l’élément se lance (toujours actif, à l’ouverture, à la demande), pas mesuré. Les agents système se modifient avec des droits admin : prévu dans une prochaine étape.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            } else {
                ScanningCard(label: "Lecture des éléments de connexion, agents et démons…")
            }
        }
        .onAppear {
            // La liste des processus sert à savoir quels agents tournent.
            model.performance.attach()
            if store.stale && !store.loading { model.scanStartup() }
        }
        .onDisappear { model.performance.detach() }
        .onChange(of: store.stale) { _, stale in if stale && !store.loading { model.scanStartup() } }
    }

    /// Orphelins d'abord, puis actifs, puis par impact.
    private func order(_ a: StartupItem, _ b: StartupItem) -> Bool {
        if a.orphan != b.orphan { return a.orphan }
        if a.leftover != b.leftover { return a.leftover }
        if a.enabled != b.enabled { return a.enabled }
        if a.impact != b.impact { return a.impact > b.impact }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    private func subtitle(_ result: StartupScanner.Result?) -> String {
        guard let result else { return "Ce qui se lance à l’ouverture de session et au démarrage" }
        let active = result.items.filter(\.enabled)
        let seconds = active.reduce(0) { $0 + $1.impact.seconds }
        let orphans = result.items.filter(\.orphan).count
        var text = "\(active.count) éléments actifs · environ \(Int(seconds.rounded())) s ajoutées au démarrage de la session"
        if orphans > 0 { text += " · \(orphans) orphelin\(orphans > 1 ? "s" : "")" }
        return text
    }

    static func openLoginSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct GroupCard: View {
    let kind: StartupItem.Kind
    let items: [StartupItem]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(kind.title).font(.system(size: 14, weight: .semibold))
                Text("\(items.count)").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                Text(kind.location).font(.system(size: 12).monospaced()).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Theme.raised.opacity(0.35))
            ForEach(items) { item in
                Rectangle().fill(Theme.hairline).frame(height: 1)
                StartupRow(item: item)
            }
        }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .cardBackground()
    }
}

private struct StartupRow: View {
    @Environment(AppModel.self) private var model
    let item: StartupItem

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    if item.orphan {
                        Tag(text: "App supprimée", foreground: Tag.red.0, background: Tag.red.1)
                    }
                    if item.leftover {
                        Tag(text: "Sans effet", foreground: Tag.grey.0, background: Tag.grey.1)
                    }
                    if item.running {
                        Tag(text: "En cours", foreground: Tag.blue.0, background: Tag.blue.1)
                    }
                }
                Text(item.detail)
                    .font(.system(size: 12, design: item.kind == .loginItem ? .default : .monospaced))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.url?.path ?? "")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            impactTag.frame(width: 110, alignment: .leading)

            Text(item.signer?.label ?? "—")
                .font(.system(size: 12))
                .foregroundStyle(item.signer?.valid == false ? Tag.orange.0 : Theme.muted)
                .lineLimit(1)
                .frame(width: 190, alignment: .leading)
                .help(item.signer?.teamID.map { "Équipe \($0)" } ?? "")

            control.frame(width: 190, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .opacity(item.enabled || item.orphan || item.leftover ? 1 : 0.6)
        .contextMenu {
            if let url = item.url {
                Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    private var impactTag: some View {
        let colors: (Color, Color) = switch item.impact {
        case .high: Tag.red
        case .medium: Tag.orange
        case .low: Tag.green
        }
        return Tag(text: "Impact \(item.impact.label)", foreground: colors.0, background: colors.1)
    }

    @ViewBuilder
    private var control: some View {
        if item.canRemove {
            Button("Supprimer") {
                if let plan = StartupScanner.removePlan(item) { model.preview(plan) }
            }
            .buttonStyle(.small)
            .foregroundStyle(Tag.red.0)
        } else if let service = item.brewService {
            Button("Voir dans Services") { model.selection = .services }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .help("Géré par brew services (\(service))")
        } else if item.canToggle {
            Toggle(item.enabled ? "Activé" : "Désactivé", isOn: Binding(
                get: { item.enabled },
                set: { on in if let plan = StartupScanner.togglePlan(item, enable: on) { model.preview(plan) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 13))
        } else if item.kind == .systemAgent {
            HStack(spacing: 8) {
                Text("admin requis").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.adaptive(light: NSColor(hex: 0x4A2A8A), dark: NSColor(hex: 0xC9B3FF)))
                Text(item.enabled ? "Activé" : "Désactivé").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        } else {
            // Éléments de connexion et agents bloqués : c'est macOS qui les gère.
            Button(item.enabled ? "Activé · Réglages…" : "Désactivé · Réglages…") { StartupPage.openLoginSettings() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(item.enabled ? Theme.accent : Theme.muted)
                .help(item.blockedInSettings
                      ? "Bloqué dans Réglages Système › Général › Ouverture (« Autoriser en arrière-plan »)."
                      : "Se règle dans Réglages Système › Général › Ouverture.")
        }
    }
}
