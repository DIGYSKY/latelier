import LAtelierCore
import SwiftUI

/// Projets › Dépendances : chaque bibliothèque directe, dans quels projets, en quelle version.
struct DependenciesPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.projectScope) private var scope
    @ViewState private var ecosystem: Ecosystem?
    @ViewState private var onlyOutdated = false
    @ViewState private var query = ""
    @ViewState private var open: String?
    @ViewState private var limit = 60

    var body: some View {
        let store = model.analysis
        PageScaffold(page: .dependances, subtitle: String(localized: "Quelles bibliothèques, dans quels projets, en quelle version")) {
            SearchField(prompt: String(localized: "Rechercher une bibliothèque"), text: $query)
            CapsuleToggle(label: String(localized: "Seulement les obsolètes"), isOn: $onlyOutdated)
        } content: {
            if let analysis = store.value {
                content(analysis)
            } else {
                ScanningCard(label: String(localized: "Lecture des manifestes et lockfiles, puis des dernières versions sur les registres…"))
            }
        }
        .onAppear { if store.stale && !store.loading { model.scanAnalysis() } }
        .onChange(of: store.stale) { _, stale in if stale && !store.loading { model.scanAnalysis() } }
        .onChange(of: ecosystem) { limit = 60 }
        .onChange(of: onlyOutdated) { limit = 60 }
        .onChange(of: query) { limit = 60 }
    }

    @ViewBuilder
    private func content(_ analysis: ProjectAnalysis) -> some View {
        // Dans la page d'un dépôt : seulement ses bibliothèques.
        let libraries = scope.map { project in
            analysis.libraries.compactMap { library -> Library? in
                var library = library
                library.uses = library.uses.filter { $0.project.standardizedFileURL == project.standardizedFileURL }
                return library.uses.isEmpty ? nil : library
            }
        } ?? analysis.libraries
        let names = analysis.projectNames
        let ecosystems = Ecosystem.allCases.filter { e in libraries.contains { $0.ecosystem == e } }
        let q = query.lowercased()
        let visible = libraries
            .filter { ecosystem == nil || $0.ecosystem == ecosystem }
            .filter { !onlyOutdated || !$0.outdated.isEmpty }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) }

        HStack(spacing: 12) {
            ChoiceChips(selection: $ecosystem, items: [(nil, String(localized: "Tous"), libraries.count)]
                + ecosystems.map { e in (e, e.label, libraries.filter { $0.ecosystem == e }.count) })
            Spacer()
            if model.analysis.loading { ProgressView().controlSize(.small) }
        }

        if libraries.isEmpty {
            Card { EmptyState(symbol: "shippingbox", title: String(localized: "Aucune dépendance trouvée"),
                              message: scope == nil ? String(localized: "Aucun package.json, Cargo.toml, pyproject.toml, go.mod… dans les projets détectés.")
                                                    : String(localized: "Ce projet ne déclare aucune dépendance externe (ou son manifeste n’est pas reconnu).")) }
        } else {
            LazyVStack(spacing: 0) {
                if visible.isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: String(localized: "Aucune bibliothèque ne correspond"))
                }
                ForEach(Array(visible.prefix(limit).enumerated()), id: \.element.id) { index, library in
                    if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    LibraryRow(library: library, names: names, open: open == library.id) {
                        withAnimation(.snappy(duration: 0.2)) { open = open == library.id ? nil : library.id }
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
            .cardBackground()

            HStack {
                if visible.count > limit {
                    Button(String(localized: "Afficher \(min(60, visible.count - limit)) de plus")) { limit += 60 }.buttonStyle(.small)
                }
                Spacer()
                Text(footnote(analysis, shown: min(limit, visible.count), total: visible.count))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
        }
        if !analysis.problems.isEmpty {
            Label(analysis.problems.joined(separator: " · "), systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(Theme.orange)
        }
    }

    private func footnote(_ analysis: ProjectAnalysis, shown: Int, total: Int) -> String {
        let projects = Set(analysis.manifests.map(\.project)).count
        return String(localized: "\(shown) sur \(total) · dépendances directes de \(projects) projets · dernières versions : npm, crates.io, PyPI, proxy Go, Packagist, Maven Central")
    }
}

private struct LibraryRow: View {
    @Environment(AppModel.self) private var model
    let library: Library
    let names: [URL: String]
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 14) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(library.name).font(.system(size: 13, weight: .bold).monospaced()).lineLimit(1)
                        Text([library.ecosystem.label, library.license].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(library.uses.count) projet\(library.uses.count > 1 ? "s" : "")")
                        .font(.system(size: 13))
                        .frame(width: 90, alignment: .leading)
                    Text(library.latest.map { String(localized: "dernière \($0)") } ?? "—")
                        .font(.system(size: 12).monospaced())
                        .lineLimit(1)
                        .frame(width: 140, alignment: .leading)
                    HStack(spacing: 6) { flags }
                        .frame(width: 310, alignment: .leading)
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 52)
                .background(open ? Theme.raised.opacity(0.5) : .clear)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "\(library.name), \(library.uses.count) projets"))
            .accessibilityValue(open ? String(localized: "déplié") : String(localized: "replié"))

            if open { details }
        }
    }

    @ViewBuilder
    private var flags: some View {
        if let severity = library.worstSeverity {
            Tag(text: String(localized: "Faille \(severity.label.lowercased())"), foreground: severity.colors.ink, background: severity.colors.fill)
        }
        let outdated = library.outdated.count
        if outdated > 0 {
            Tag(text: (outdated > 1 ? String(localized: "\(outdated) obsolètes") : String(localized: "\(outdated) obsolète")), foreground: Tag.orange.0, background: Tag.orange.1)
        }
        if library.versionCount > 1 {
            Tag(text: "\(library.versionCount) versions", foreground: Tag.blue.0, background: Tag.blue.1)
        }
        if library.worstSeverity == nil && outdated == 0 && library.versionCount <= 1 {
            Tag(text: library.latest == nil ? String(localized: "Non vérifiée") : String(localized: "À jour"),
                foreground: library.latest == nil ? Tag.grey.0 : Tag.green.0,
                background: library.latest == nil ? Tag.grey.1 : Tag.green.1)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(library.uses.sorted { (names[$0.project] ?? "") < (names[$1.project] ?? "") }) { use in
                HStack(spacing: 12) {
                    Button(names[use.project] ?? use.projectName) { model.showRepository(use.project) }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .frame(width: 170, alignment: .leading)
                        .help(use.project.abbreviatingHome())
                    Text(use.version.isEmpty ? (use.requirement ?? "?") : use.version)
                        .font(.system(size: 12).monospaced())
                        .foregroundStyle(color(use.gap))
                        .frame(width: 110, alignment: .leading)
                    Text(note(use)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Spacer()
                }
            }
            if let plan = DependencyFix.alignPlan(library), let latest = library.latest {
                Button(String(localized: "Aligner tous les projets sur \(latest)…")) { model.preview(plan) }
                    .buttonStyle(PillButtonStyle(kind: .smallFilled))
                    .padding(.top, 4)
            } else if !library.outdated.isEmpty {
                Text(String(localized: "Mise à jour à faire à la main : \(library.outdated.first!.manager.label) n’a pas de commande pour changer la version."))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.leading, 44)
        .padding(.trailing, 18)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .background(Theme.raised.opacity(0.5))
    }

    private func color(_ gap: UpdateGap?) -> Color {
        switch gap {
        case nil: library.latest == nil ? .primary : Tag.green.0
        case .major: Tag.red.0
        default: Tag.orange.0
        }
    }

    private func note(_ use: Library.Use) -> String {
        var parts: [String] = []
        if let gap = use.gap { parts.append(String(localized: "écart \(gap.label.lowercased())")) } else if library.latest != nil { parts.append(String(localized: "à jour")) }
        if use.dev { parts.append("dev") }
        if use.version.isEmpty { parts.append(String(localized: "sans lockfile")) }
        if let requirement = use.requirement, requirement != use.version, !requirement.isEmpty { parts.append("demande \(requirement)") }
        parts.append(use.manifest)
        return parts.joined(separator: " · ")
    }
}
