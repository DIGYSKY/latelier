import LAtelierCore
import SwiftUI

/// Paquets › Inventaire : tout ce qui est installé globalement, à jour ou non.
struct InventoryPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var source: PackageSource?
    @ViewState private var query = ""
    @ViewState private var showDependencies = false

    var body: some View {
        let store = model.packages
        PageScaffold(page: .inventaire, subtitle: String(localized: "Tout ce qui est installé globalement sur la machine, à jour ou non")) {
            SearchField(prompt: String(localized: "Rechercher un paquet"), text: $query)
        } content: {
            if store.scanning && store.packages.isEmpty {
                ScanningCard(label: String(localized: "Lecture des paquets installés…"))
            } else if store.packages.isEmpty {
                Card { EmptyState(symbol: "shippingbox", title: String(localized: "Aucun paquet trouvé"), message: String(localized: "Homebrew, npm, cargo et mas sont introuvables.")) }
            } else {
                sourceTiles
                table
                if dependencyCount > 0 {
                    Toggle(String(localized: "Afficher les \(dependencyCount) dépendances Homebrew installées automatiquement"), isOn: $showDependencies)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
            }
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

    private var listed: [Package] {
        model.packages.packages.filter { showDependencies || $0.onRequest }
    }

    private var dependencyCount: Int { model.packages.packages.filter { !$0.onRequest }.count }

    private var visible: [Package] {
        let q = query.lowercased()
        return listed
            .filter { source == nil || $0.source == source }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.summary.lowercased().contains(q) }
    }

    private var sourceTiles: some View {
        let sources: [PackageSource?] = [nil] + PackageSource.allCases.filter { s in listed.contains { $0.source == s } }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach(sources, id: \.self) { item in
                let packages = listed.filter { item == nil || $0.source == item }
                let updates = packages.filter(\.hasUpdate).count
                let selected = source == item
                Button { source = item } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item?.label ?? String(localized: "Tout")).font(.system(size: 13, weight: .semibold))
                        Text("\(packages.count)").font(.system(size: 22, weight: .bold))
                        Text(updates > 0 ? String(localized: "\(updates) à mettre à jour") : String(localized: "tout à jour"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(updates > 0 ? Tag.blue.0 : Tag.green.0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(selected ? Theme.raised : Theme.cardFill, in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(selected ? Theme.accent.opacity(0.6) : Theme.cardBorder, lineWidth: selected ? 1.5 : 1)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(String(localized: "Paquet")).frame(maxWidth: .infinity, alignment: .leading)
                Text("Source").frame(width: 90, alignment: .leading)
                Text("Version").frame(width: 110, alignment: .leading)
                Text(String(localized: "Installé")).frame(width: 80, alignment: .leading)
                Text(String(localized: "Taille")).frame(width: 70, alignment: .trailing)
                Text(String(localized: "État")).frame(width: 100, alignment: .leading)
                Text("Actions").frame(width: 140, alignment: .trailing)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Theme.cardFill.opacity(0.7))

            if visible.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: String(localized: "Aucun paquet ne correspond"))
            }
            ForEach(visible) { package in
                Rectangle().fill(Theme.hairline).frame(height: 1)
                InventoryRow(package: package, measuring: model.packages.measuring)
            }
        }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .cardBackground()
    }
}

private struct InventoryRow: View {
    @Environment(AppModel.self) private var model
    let package: Package
    let measuring: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(package.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if !package.detail.isEmpty {
                    Text(package.detail).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SourceLabel(text: package.sourceLabel).frame(width: 90, alignment: .leading)
            Text(package.version)
                .font(.system(size: 12).monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 110, alignment: .leading)
            Text(package.installedAt.map(FrenchDate.monthYear) ?? "—")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .frame(width: 80, alignment: .leading)
            Text(package.bytes.map(Format.bytes) ?? (measuring ? "…" : "—"))
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 70, alignment: .trailing)
            state.frame(width: 100, alignment: .leading)
            HStack(spacing: 6) {
                if let url = package.homepage {
                    Link(destination: url) { Image(systemName: "safari") }
                        .help(String(localized: "Site du projet"))
                        .accessibilityLabel(String(localized: "Site de \(package.name)"))
                        .foregroundStyle(Theme.muted)
                }
                Button(String(localized: "Désinstaller")) {
                    Task {
                        // Homebrew refuse de retirer une formule dont un autre paquet dépend : on le dit avant.
                        if package.source == .homebrew, !package.isCask {
                            let users = await Brew.dependents(of: package.identifier, runner: model.runner)
                            if !users.isEmpty {
                                model.actionNotice = String(localized: "\(package.name) est requis par \(users.joined(separator: ", ")). Désinstallez d’abord ces paquets, ou gardez-le.")
                                return
                            }
                        }
                        if let plan = PackagePlans.uninstall(package) { model.preview(plan) }
                    }
                }
                .buttonStyle(.small)
                .disabled(!canUninstall)
                .help(uninstallHelp)
            }
            .fixedSize()
            .frame(width: 140, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .frame(minHeight: 50)
    }

    private var canUninstall: Bool {
        package.lockReason == nil && package.uninstallCommand != nil && package.onRequest
    }

    private var uninstallHelp: String {
        if let reason = package.lockReason { return reason }
        if package.uninstallCommand == nil { return String(localized: "À désinstaller depuis le Finder (Applications).") }
        if !package.onRequest { return String(localized: "Dépendance : Homebrew la retire avec le paquet qui l’utilise.") }
        return package.uninstallCommand?.displayString ?? ""
    }

    @ViewBuilder
    private var state: some View {
        if let worst = package.vulnerabilities.map(\.severity).max() {
            Tag(text: String(localized: "Faille \(worst.label.lowercased())"), foreground: worst.colors.ink, background: worst.colors.fill)
                .help(package.vulnerabilities.map { "\($0.displayID) : \($0.summary)" }.joined(separator: "\n"))
        } else if package.lockReason != nil, package.source != .npm {
            Tag(text: package.lockReason!, foreground: Tag.grey.0, background: Tag.grey.1)
        } else if package.hasUpdate {
            Tag(text: String(localized: "Mise à jour"), foreground: Tag.blue.0, background: Tag.blue.1)
        } else if package.pinned {
            Tag(text: String(localized: "Épinglé"), foreground: Tag.grey.0, background: Tag.grey.1)
        } else {
            Tag(text: String(localized: "À jour"), foreground: Tag.green.0, background: Tag.green.1)
        }
    }
}
