import AppKit
import LAtelierCore
import SwiftUI

/// Stockage › Applications › Désinstalleur : l'app et toutes ses données, en une fois, après aperçu.
struct UninstallerPage: View {
    enum Sort: String, CaseIterable { case size, used, unused, name }

    @Environment(AppModel.self) private var model
    @ViewState private var query = ""
    @ViewState private var sort = Sort.size
    @ViewState private var selectedID: String?
    /// Données décochées, par chemin.
    @ViewState private var unchecked: Set<String> = []
    @ViewState private var keepPreferences = false

    var body: some View {
        let store = model.installedApps
        let entries = store.value ?? []
        let list = sorted(entries.filter { query.isEmpty || $0.app.name.localizedCaseInsensitiveContains(query) })
        PageScaffold(page: .desinstalleur, subtitle: entries.isEmpty ? String(localized: "L’app et tous ses fichiers, en une fois")
                     : String(localized: "\(entries.count) apps installées · l’app et tous ses fichiers, en une fois")) {
            TextField(String(localized: "Rechercher une app"), text: $query)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .frame(width: 220, height: 36)
                .background(Theme.raised, in: .capsule)
                .overlay(Capsule().strokeBorder(Theme.hairline))
            Button { model.scanInstalledApps() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(PillButtonStyle(kind: .small))
                .disabled(store.loading)
                .help(String(localized: "Relire les apps installées"))
        } content: {
            GlassSegments(selection: $sort, items: [(.size, String(localized: "Plus lourdes")), (.used, String(localized: "Moins utilisées")),
                                                    (.unused, String(localized: "Inutilisées depuis 3 mois")), (.name, String(localized: "Nom"))], compact: true)
            if store.loading && entries.isEmpty {
                ScanningCard(label: String(localized: "Lecture des apps de /Applications et de leurs données…"))
            } else if list.isEmpty {
                Card { EmptyState(symbol: "magnifyingglass", title: String(localized: "Aucune app"), message: query.isEmpty ? String(localized: "Aucune app dans /Applications.") : String(localized: "Aucune app ne correspond à « \(query) ».")) }
            } else {
                let current = list.first { $0.id == selectedID } ?? list[0]
                HStack(alignment: .top, spacing: 14) {
                    appList(list, current: current)
                        .frame(width: 330)
                    detail(current)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear { if store.stale && !store.loading { model.scanInstalledApps() } }
        .onChange(of: store.stale) { _, stale in if stale && !store.loading { model.scanInstalledApps() } }
    }

    private func sorted(_ entries: [AppEntry]) -> [AppEntry] {
        let old = Date().addingTimeInterval(-90 * 86_400)
        switch sort {
        case .size: return entries.sorted { $0.total > $1.total }
        case .name: return entries.sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
        case .used: return entries.sorted { ($0.app.lastUsed ?? .distantPast) < ($1.app.lastUsed ?? .distantPast) }
        case .unused:
            // Sans date connue, l'app n'est pas comptée comme inutilisée (on ne sait pas).
            return entries.filter { ($0.app.lastUsed ?? .now) < old }.sorted { $0.total > $1.total }
        }
    }

    private func usedLabel(_ app: InstalledApp) -> (String, Bool) {
        if model.runningTarget(for: app) != nil { return (String(localized: "Ouverte"), false) }
        guard let date = app.lastUsed else { return (String(localized: "Dernière utilisation inconnue"), false) }
        let days = Int(Date().timeIntervalSince(date) / 86_400)
        if days < 1 { return (String(localized: "Utilisée aujourd’hui"), false) }
        if days < 2 { return (String(localized: "Utilisée hier"), false) }
        if days < 30 { return (String(localized: "Utilisée il y a \(days) j"), false) }
        return (String(localized: "Pas utilisée depuis \(days / 30) mois"), days >= 90)
    }

    private func appList(_ list: [AppEntry], current: AppEntry) -> some View {
        VStack(spacing: 2) {
            ForEach(list) { entry in
                let selected = entry.id == current.id
                let used = usedLabel(entry.app)
                Button {
                    selectedID = entry.id
                    unchecked = []
                } label: {
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: entry.app.url.path))
                            .resizable().frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.app.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(used.0).font(.system(size: 11, weight: used.1 ? .semibold : .regular))
                                .foregroundStyle(used.1 ? Theme.orange : Theme.muted)
                        }
                        Spacer(minLength: 4)
                        Text(Format.bytes(entry.total)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(selected ? Theme.raised : .clear, in: .rect(cornerRadius: 12, style: .continuous))
                    .shadow(color: Theme.shadow.opacity(selected ? 0.12 : 0), radius: 5, y: 2)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(8)
        .cardBackground()
    }

    private func isOn(_ part: AppEntry.PartSize) -> Bool {
        if keepPreferences && part.part.isPreference { return false }
        return !unchecked.contains(part.id)
    }

    private func detail(_ entry: AppEntry) -> some View {
        let app = entry.app
        let running = model.runningTarget(for: app)
        let chosen = entry.parts.filter(isOn)
        let total = (app.bytes ?? 0) + chosen.compactMap(\.bytes).reduce(0, +)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.system(size: 19, weight: .bold))
                    Text([String(localized: "Version \(app.version ?? "?")"), app.bundleID].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
                Spacer()
                Button(String(localized: "Afficher dans le Finder")) { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
                    .buttonStyle(PillButtonStyle(kind: .small))
            }

            VStack(spacing: 0) {
                partRow(path: app.url.path, kind: app.fromAppStore ? String(localized: "Application (App Store)") : "Application", bytes: app.bytes, on: true, fixed: true) {}
                ForEach(entry.parts) { part in
                    Divider().opacity(0.5)
                    partRow(path: part.part.url.abbreviatingHome(), kind: part.part.kind, bytes: part.bytes, on: isOn(part),
                            fixed: keepPreferences && part.part.isPreference) {
                        if unchecked.contains(part.id) { unchecked.remove(part.id) } else { unchecked.insert(part.id) }
                    }
                }
            }
            .background(Theme.raised.opacity(0.55), in: .rect(cornerRadius: 14, style: .continuous))

            Toggle(String(localized: "Garder les réglages (réinstallation plus tard)"), isOn: $keepPreferences)
                .toggleStyle(.checkbox)
                .disabled(!entry.parts.contains { $0.part.isPreference })

            if running != nil {
                notice(String(localized: "\(app.name) est ouverte. Elle sera quittée proprement avant la désinstallation."), color: Theme.orange)
            }
            if let cask = entry.cask {
                notice(String(localized: "Installée via Homebrew : la désinstallation passera par brew uninstall --cask \(cask), puis ses données iront à la corbeille."), color: Theme.accent)
            } else if !app.deletable {
                notice(String(localized: "Cette app appartient au système (App Store ou installeur) : le Finder demandera votre mot de passe pour la mettre à la corbeille."), color: Theme.muted)
            }
            if entry.parts.contains(where: { $0.part.isContainer }) {
                Text(String(localized: "Le conteneur d’une app sandboxée n’est pas mesuré : macOS demande une autorisation pour le lire."))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }

            HStack {
                (Text("À libérer ") + Text(Format.bytes(total)).bold()).font(.system(size: 15))
                Spacer()
                Button(String(localized: "Désinstaller \(app.name)…")) { uninstall(entry, parts: chosen, running: running) }
                    .buttonStyle(.primary(tint: Theme.red))
            }
        }
        .padding(20)
        .cardBackground()
    }

    private func notice(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(color == Theme.muted ? Color.primary : color)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private func partRow(path: String, kind: String, bytes: Int64?, on: Bool, fixed: Bool, toggle: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .font(.system(size: 16))
                .foregroundStyle(fixed ? Theme.muted : on ? Theme.accent : Theme.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text(path).font(.system(size: 12).monospaced()).lineLimit(1).truncationMode(.middle)
                Text(kind).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(bytes.map(Format.bytes) ?? String(localized: "non mesuré")).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(bytes == nil ? Theme.muted : .primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(.rect)
        .onTapGesture { if !fixed { toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(on ? String(localized: "coché") : String(localized: "non coché"))
    }

    private func uninstall(_ entry: AppEntry, parts: [AppEntry.PartSize], running: ProcessTarget?) {
        let brew = entry.cask.flatMap { cask in model.runner.locator.locate("brew").map { ($0.path, cask) } }
        let plan = AppInventory.uninstallPlan(app: entry.app, parts: parts.map { ($0.part, $0.bytes ?? 0) }, running: running, brew: brew)
        model.preview(plan)
    }
}
