import LAtelierCore
import SwiftUI

/// Paquets › Mises à jour : tout ce qui a une version plus récente, toutes sources confondues.
struct UpdatesPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var source: PackageSource?
    @ViewState private var query = ""
    @ViewState private var showCommands = false

    var body: some View {
        let store = model.packages
        PageScaffold(page: .majs, subtitle: subtitle) {
            SearchField(prompt: String(localized: "Rechercher un paquet"), text: $query)
            Button("Vérifier", systemImage: "arrow.clockwise") { model.scanPackages() }
                .buttonStyle(.secondary)
                .disabled(store.scanning)
        } content: {
            if store.scanning && store.packages.isEmpty {
                ScanningCard(label: String(localized: "Interrogation de Homebrew, npm, cargo, mas et rustup…"))
            } else if store.updates.isEmpty {
                Card {
                    EmptyState(symbol: "checkmark.circle", title: String(localized: "Tout est à jour"),
                               message: store.sources.isEmpty ? String(localized: "Aucun gestionnaire de paquets trouvé.") : String(localized: "\(store.packages.count) paquets vérifiés."))
                }
            } else {
                SourceChips(selection: $source, counts: chipCounts)
                if visible.isEmpty {
                    Card { EmptyState(symbol: "magnifyingglass", title: String(localized: "Aucun paquet ne correspond")) }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, package in
                            if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                            UpdateRow(package: package, selected: isSelected(package)) { toggle(package) }
                        }
                    }
                    .clipShape(.rect(cornerRadius: 22, style: .continuous))
                    .cardBackground()
                }
                if showCommands {
                    ConsoleBlock(text: chosen.isEmpty ? String(localized: "Aucune mise à jour sélectionnée.") : chosen.compactMap(\.upgradeCommand).map { "$ " + $0.displayString }.joined(separator: "\n"))
                }
            }
            ForEach(store.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.orange)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !store.updates.isEmpty { bottomBar }
        }
        .onAppear {
            if store.stale && !store.scanning { model.scanPackages() }
            // Arrivée depuis une news : le paquet concerné est filtré.
            if let focus = model.packageFocus {
                query = focus
                model.packageFocus = nil
            }
        }
        .onChange(of: store.stale) { _, stale in if stale && !store.scanning { model.scanPackages() } }
    }

    private var subtitle: String {
        let store = model.packages
        if store.scanning { return String(localized: "Vérification des mises à jour…") }
        guard let finished = store.finishedAt else { return "Homebrew, npm, cargo, Mac App Store, rustup" }
        let updates = store.updates.count
        return "\(store.packages.count) paquets installés · \(updates) mise\(updates > 1 ? "s" : "") à jour · vérifié \(RelativeDate.french(finished).replacingOccurrences(of: "aujourd’hui", with: "à \(finished.formatted(date: .omitted, time: .shortened))"))"
    }

    private var chipCounts: [(source: PackageSource?, count: Int)] {
        let updates = model.packages.updates
        return [(nil, updates.count)] + PackageSource.allCases.compactMap { source in
            let count = updates.filter { $0.source == source }.count
            return count > 0 ? (source, count) : nil
        }
    }

    private var visible: [Package] {
        let q = query.lowercased()
        return model.packages.updates
            .filter { source == nil || $0.source == source }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.identifier.lowercased().contains(q) }
    }

    private func isSelected(_ package: Package) -> Bool {
        model.packages.selection.contains(package.id) && package.lockReason == nil && !package.pinned
    }

    private func toggle(_ package: Package) {
        guard package.lockReason == nil, !package.pinned else { return }
        if model.packages.selection.contains(package.id) {
            model.packages.selection.remove(package.id)
        } else {
            model.packages.selection.insert(package.id)
        }
    }

    private var chosen: [Package] { model.packages.updates.filter(isSelected) }

    private var bottomBar: some View {
        let count = chosen.count
        return HStack(spacing: 12) {
            (Text((count > 1 ? String(localized: "\(count) mises à jour sélectionnées") : String(localized: "\(count) mise à jour sélectionnée"))).bold()
                + Text(String(localized: " · les mises à jour majeures ne sont pas cochées par défaut")).foregroundStyle(Theme.muted))
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(showCommands ? String(localized: "Masquer les commandes") : String(localized: "Voir les commandes")) { showCommands.toggle() }
                .buttonStyle(.secondary)
            Button(String(localized: "Mettre à jour (\(count))")) {
                let skipped = model.packages.updates.filter { $0.lockReason != nil && model.packages.selection.contains($0.id) }
                if let plan = PackagePlans.upgrade(chosen + skipped) { model.preview(plan) }
            }
            .buttonStyle(.primary)
            .disabled(count == 0)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.leading, 22)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background {
            Capsule().fill(.regularMaterial)
                .overlay(Capsule().fill(Theme.headerFill))
                .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: 1))
                .shadow(color: Theme.shadow.opacity(0.22), radius: 16, y: 12)
        }
        .padding(.leading, 22)
        .padding(.trailing, 30)
        .padding(.bottom, 14)
    }
}

private struct UpdateRow: View {
    let package: Package
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        let locked = package.lockReason != nil || package.pinned
        HStack(spacing: 14) {
            Image(systemName: selected ? "checkmark.square.fill" : "square")
                .font(.system(size: 17))
                .foregroundStyle(selected ? Theme.accent : Theme.muted.opacity(locked ? 0.4 : 1))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(package.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if !package.detail.isEmpty {
                    Text(package.detail).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SourceLabel(text: package.sourceLabel).frame(width: 96, alignment: .leading)
            (Text(package.version) + Text(" → ") + Text(package.latest ?? "?").bold())
                .font(.system(size: 12).monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 170, alignment: .leading)
            Group {
                if let gap = package.gap { Tag.gap(gap) }
            }
            .frame(width: 76, alignment: .leading)
            Group {
                if let worst = package.vulnerabilities.map(\.severity).max(), flag == nil {
                    Tag(text: String(localized: "Faille \(worst.label.lowercased())"), foreground: worst.colors.ink, background: worst.colors.fill)
                        .help(package.vulnerabilities.map { "\($0.displayID) : \($0.summary)" }.joined(separator: "\n"))
                } else {
                    Text(flag ?? "")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tag.orange.0)
                        .lineLimit(1)
                }
            }
            .frame(width: 110, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .background(selected ? Theme.accent.opacity(0.06) : .clear)
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
        .opacity(locked ? 0.7 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(selected ? String(localized: "coché") : String(localized: "non coché"))
        .accessibilityAction(named: selected ? String(localized: "Décocher") : String(localized: "Cocher"), toggle)
        .help(package.upgradeCommand?.displayString ?? "")
    }

    private var flag: String? {
        if let reason = package.lockReason { return reason }
        if package.pinned { return String(localized: "Épinglé") }
        return nil
    }
}
