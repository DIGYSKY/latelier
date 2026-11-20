import AppKit
import LAtelierCore
import SwiftUI

/// Projets : la liste des dépôts (du plus récemment modifié au plus ancien), puis une page par dépôt
/// qui rassemble tout : git, commandes, dépendances, sécurité, couverture.
struct ReposPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.repos
        Group {
            if let id = model.openRepo, let repo = store.repos.first(where: { $0.id == id }) {
                RepoPage(repo: repo)
            } else {
                RepoListPage()
            }
        }
        .onAppear { if store.stale && !store.scanning { model.scanRepos() } }
        .onChange(of: store.stale) { _, stale in if stale && !store.scanning { model.scanRepos() } }
    }
}

/// Onglets de la page d'un dépôt.
enum RepoTab: String, CaseIterable {
    case git, commands, dependencies, security, coverage

    var label: String {
        switch self {
        case .git: "Git"
        case .commands: "Commandes"
        case .dependencies: "Dépendances"
        case .security: "Sécurité"
        case .coverage: "Couverture"
        }
    }
}

private struct RepoListPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var filter: RepoFilter = .all
    @ViewState private var query = ""
    @ViewState private var byName = false

    var body: some View {
        let store = model.repos
        PageScaffold(title: "Projets", subtitle: subtitle) {
            SearchField(prompt: "Rechercher un projet", text: $query)
            Button(store.fetching ? "Fetch en cours…" : "Fetch de tous les dépôts", systemImage: "arrow.clockwise") {
                model.fetchAll()
            }
            .buttonStyle(.secondary)
            .fixedSize()
            .disabled(store.fetching || store.scanning || store.repos.isEmpty)
        } content: {
            if model.projectRoots.isEmpty {
                Card {
                    EmptyState(symbol: "folder.badge.plus", title: "Aucun dossier de projets",
                               message: "Ajoutez vos dossiers dans Réglages › Projets.")
                }
            } else if store.scanning && store.repos.isEmpty {
                ScanningCard(label: "Recherche des dépôts git dans \(model.projectRoots.map { $0.abbreviatingHome() }.joined(separator: ", "))…")
            } else if store.repos.isEmpty {
                Card { EmptyState(symbol: "arrow.triangle.branch", title: "Aucun dépôt git trouvé") }
            } else {
                HStack(spacing: 12) {
                    FilterChips(selection: $filter, counts: counts)
                    Spacer()
                    GlassSegments(selection: $byName, items: [(false, "Récents"), (true, "Nom")], compact: true)
                }
                globalViews
                LazyVStack(spacing: 6) {
                    ForEach(visible) { repo in
                        RepoRow(repo: repo, showParent: duplicateNames.contains(repo.name)) { model.openRepository(repo.url) }
                    }
                }
                if visible.isEmpty {
                    Card { EmptyState(symbol: "magnifyingglass", title: "Aucun projet ne correspond") }
                }
            }
        }
    }

    /// Vues de tous les projets à la fois (anciennes sous-pages).
    private var globalViews: some View {
        HStack(spacing: 8) {
            Text("Tous les projets :").font(.system(size: 12)).foregroundStyle(Theme.muted)
            ForEach([Page.modifications, .commandes, .dependances, .securite, .couverture], id: \.self) { page in
                Button { model.selection = page } label: { Label(page.title, systemImage: page.symbol) }
                    .buttonStyle(PillButtonStyle(kind: .small))
            }
        }
    }

    private var subtitle: String {
        let store = model.repos
        if let message = store.message { return message }
        if store.scanning { return "Analyse des dépôts…" }
        let roots = model.projectRoots.map { $0.abbreviatingHome() }.joined(separator: " et ")
        return "\(store.repos.count) dépôt\(store.repos.count > 1 ? "s" : "") git dans \(roots) · du plus récemment modifié au plus ancien"
    }

    private var visible: [RepoStatus] {
        let q = query.lowercased()
        let list = model.repos.repos.filter(filter.matches).filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.url.path.lowercased().contains(q) }
        if byName { return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        return list.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    private var duplicateNames: Set<String> {
        Set(Dictionary(grouping: model.repos.repos, by: \.name).filter { $0.value.count > 1 }.keys)
    }

    private var counts: [RepoFilter: Int] {
        Dictionary(uniqueKeysWithValues: RepoFilter.allCases.map { f in (f, model.repos.repos.filter(f.matches).count) })
    }
}

/// Une ligne de la liste : nom, chemin, branche, état, dernière activité, failles et couverture si connues.
private struct RepoRow: View {
    @Environment(AppModel.self) private var model
    let repo: RepoStatus
    var showParent = false
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(repo.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if showParent {
                            Text(repo.url.deletingLastPathComponent().lastPathComponent).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        ForEach(repo.languages.prefix(3), id: \.self) { language in
                            Text(language).font(.system(size: 11)).foregroundStyle(Theme.muted)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Theme.hairline, in: .capsule)
                        }
                    }
                    Text(repo.url.abbreviatingHome()).font(.system(size: 11).monospaced()).foregroundStyle(Theme.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("⎇ \(repo.branch ?? "détaché")").font(.system(size: 12).monospaced()).lineLimit(1).frame(width: 150, alignment: .leading)
                StateLabel(repo: repo).frame(width: 140, alignment: .leading)
                badges.frame(width: 120, alignment: .leading)
                Text(repo.lastActivity.map { RelativeDate.french($0) } ?? "—").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .frame(width: 110, alignment: .trailing)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Theme.rowFill, in: .rect(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.cardBorder))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 6) {
            if let analysis = model.analysis.value {
                let vulns = analysis.vulnerablePackages.filter { $0.project?.standardizedFileURL == repo.url.standardizedFileURL }
                if !vulns.isEmpty {
                    let worst = vulns.map(\.severity).max() ?? .unknown
                    Tag(text: "\(vulns.count) faille\(vulns.count > 1 ? "s" : "")", foreground: worst >= .high ? Tag.red.0 : Tag.orange.0,
                        background: worst >= .high ? Tag.red.1 : Tag.orange.1)
                }
            }
            if let coverage = model.coverage.value?.first(where: { $0.project.standardizedFileURL == repo.url.standardizedFileURL })?.report?.lines {
                Text("\(Int(coverage.rounded())) %").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(coverageColor(coverage, threshold: model.preferences.coverageThreshold))
                    .help("Couverture de tests")
            }
        }
    }
}

/// Page d'un dépôt : en-tête, onglets, et chaque écran limité à ce projet.
private struct RepoPage: View {
    @Environment(AppModel.self) private var model
    let repo: RepoStatus

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { model.openRepo = nil } label: { Label("Projets", systemImage: "chevron.left") }
                    .buttonStyle(PillButtonStyle(kind: .small))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(repo.name).font(.system(size: 24, weight: .bold))
                        StateLabel(repo: repo)
                    }
                    Text("\(repo.url.abbreviatingHome()) · ⎇ \(repo.branch ?? "détaché")" + (repo.lastActivity.map { " · modifié \(RelativeDate.french($0))" } ?? ""))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                OpenInMenu(project: repo.url)
            }
            GlassSegments(selection: $model.repoTab, items: RepoTab.allCases.map { ($0, $0.label) })
                .fixedSize()
        }
        .padding(.leading, 22)
        .padding(.trailing, 30)
        .padding(.top, 6)
        Group {
            switch model.repoTab {
            case .git:
                ScrollView {
                    RepoDetail(repo: repo).id(repo.id)
                        .padding(.leading, 22).padding(.trailing, 30).padding(.bottom, 20).padding(.top, 6)
                }
            case .commands: CommandsPage()
            case .dependencies: DependenciesPage()
            case .security: SecurityPage()
            case .coverage: CoveragePage()
            }
        }
        .environment(\.projectScope, repo.url)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            if model.analysis.stale && !model.analysis.loading { model.scanAnalysis() }
            if model.coverage.stale && !model.coverage.loading { model.scanCoverage() }
        }
    }
}

enum RepoFilter: String, CaseIterable, Hashable {
    case all, modified, toPush, behind, noRemote, inactive

    var label: String {
        switch self {
        case .all: "Tous"
        case .modified: "Modifiés"
        case .toPush: "À pousser"
        case .behind: "En retard"
        case .noRemote: "Sans remote"
        case .inactive: "Inactifs"
        }
    }

    func matches(_ repo: RepoStatus) -> Bool {
        switch self {
        case .all: true
        case .modified: !repo.changes.isEmpty
        case .toPush: repo.canPush
        case .behind: repo.behind > 0
        case .noRemote: !repo.hasRemote
        case .inactive: repo.isInactive()
        }
    }
}

private struct FilterChips: View {
    @Binding var selection: RepoFilter
    let counts: [RepoFilter: Int]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(RepoFilter.allCases, id: \.self) { filter in
                let selected = selection == filter
                Button { selection = filter } label: {
                    HStack(spacing: 5) {
                        Text(filter.label)
                        if filter != .all, let count = counts[filter], count > 0 {
                            Text("\(count)").foregroundStyle(Theme.muted)
                        }
                    }
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background {
                        if selected { Capsule().fill(Theme.raised).shadow(color: Theme.shadow.opacity(0.15), radius: 4, y: 2) }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.rowFill, in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.cardBorder))
    }
}

/// « 3 modifiés », « ↑2 à pousser », « À jour »…
struct StateLabel: View {
    let repo: RepoStatus

    var body: some View {
        let (text, color) = describe
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(color).lineLimit(1)
    }

    private var describe: (String, Color) {
        switch repo.state {
        case .conflict: (repo.operationInProgress?.capitalizedFirst ?? "Conflit", Theme.red)
        case .modified: ("\(repo.changes.count) modifié\(repo.changes.count > 1 ? "s" : "")", Theme.orange)
        case .diverged: ("↑\(repo.ahead) ↓\(repo.behind) divergé", Theme.red)
        case .ahead: ("↑\(repo.ahead) à pousser", Theme.orange)
        case .behind: ("↓\(repo.behind) en retard", Tag.blue.0)
        case .noRemote: ("Sans remote", Theme.orange)
        case .noUpstream: ("Branche non publiée", Theme.orange)
        case .clean: ("À jour", Tag.green.0)
        }
    }
}

/// Détail d'un dépôt : actions, fichiers modifiés et commit, derniers commits, branches.
private struct RepoDetail: View {
    @Environment(AppModel.self) private var model
    let repo: RepoStatus
    @ViewState private var unchecked: Set<String> = []
    @ViewState private var message = ""
    @ViewState private var fetching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let error = repo.error {
                Callout(symbol: "xmark.octagon", tint: .red) { Text(error) }
            }
            if let operation = repo.operationInProgress {
                Callout(symbol: "exclamationmark.triangle", tint: .orange) {
                    Text("\(operation.capitalizedFirst) : terminez-le dans le terminal. L’Atelier ne propose aucune action en attendant.")
                }
            } else if !repo.hasRemote {
                Callout(symbol: "exclamationmark.triangle", tint: .orange) {
                    (Text("Pas de remote. ").bold() + Text("Ce dépôt n’est sauvegardé nulle part. Ajoutez un remote pour le pousser."))
                }
            }

            changesSection

            HStack(alignment: .top, spacing: 18) {
                section("Derniers commits") {
                    if repo.recentCommits.isEmpty {
                        Text("Aucun commit.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                    ForEach(repo.recentCommits, id: \.hash) { commit in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(commit.hash).font(.system(size: 12).monospaced()).foregroundStyle(Theme.link)
                            Text(commit.subject).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(RelativeDate.french(commit.date)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                }
                section("Branches") {
                    ForEach(repo.branches) { branch in
                        HStack(spacing: 8) {
                            Text(branch.name).font(.system(size: 12).monospaced()).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(note(for: branch)).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: 260)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private var header: some View {
        let busy = repo.operationInProgress != nil
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(repo.name).font(.system(size: 20, weight: .bold))
                Text([repo.url.abbreviatingHome(), repo.remoteURL ?? "aucun remote"].joined(separator: " · "))
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                OpenInMenu(project: repo.url)
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 22).padding(.horizontal, 4)
                Button(fetching ? "Fetch…" : "Fetch") { fetch() }
                    .buttonStyle(.small)
                    .disabled(!repo.hasRemote || fetching)
                Button("Pull ↓\(repo.behind)") { model.preview(GitClient.pullPlan(repo)) }
                    .buttonStyle(.small)
                    .disabled(busy || repo.upstream == nil || repo.behind == 0)
                Button(repo.upstream == nil && repo.hasRemote ? "Publier la branche" : "Push ↑\(repo.ahead)") {
                    if let plan = GitClient.pushPlan(repo) { model.preview(plan) }
                }
                .buttonStyle(PillButtonStyle(kind: .small))
                .disabled(busy || !repo.hasRemote || repo.branch == nil || (repo.upstream != nil && repo.ahead == 0))
                Spacer()
            }
        }
    }

    private var changesSection: some View {
        let chosen = repo.changes.filter { !unchecked.contains($0.id) }
        let plan = GitClient.commitPlan(repo, files: chosen, message: message)
        return section("Modifications · \(repo.branch ?? "HEAD détaché")") {
            if repo.changes.isEmpty {
                Text("Aucune modification locale.").font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.vertical, 6)
            } else {
                VStack(spacing: 4) {
                    ForEach(repo.changes) { change in
                        FileRow(change: change, checked: !unchecked.contains(change.id)) {
                            if unchecked.contains(change.id) { unchecked.remove(change.id) } else { unchecked.insert(change.id) }
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField("Message de commit", text: $message)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 40)
                        .background(Theme.raised, in: .capsule)
                        .overlay(Capsule().strokeBorder(Theme.hairline))
                        .onSubmit { if let plan { model.preview(plan) } }
                    Button("Commit (\(chosen.count))") { if let plan { model.preview(plan) } }
                        .buttonStyle(.primary)
                        .disabled(plan == nil || repo.operationInProgress != nil)
                }
                .padding(.top, 4)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(for branch: GitBranch) -> String {
        var parts: [String] = []
        if branch.isCurrent { parts.append("courante") }
        if branch.ahead > 0 { parts.append("↑\(branch.ahead)") }
        if branch.behind > 0 { parts.append("↓\(branch.behind)") }
        if branch.upstreamGone { parts.append("distant supprimé") }
        if branch.merged { parts.append("fusionnée · supprimable") }
        if branch.upstream == nil && !branch.isCurrent && !branch.merged { parts.append("locale") }
        return parts.joined(separator: " · ")
    }

    private func fetch() {
        fetching = true
        Task {
            let entry = await model.runQuietly(GitClient.fetchPlan([repo]))
            fetching = false
            if case .failure(let text) = entry.outcome { model.repos.message = text }
        }
    }
}

private struct FileRow: View {
    let change: GitFileChange
    let checked: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 15))
                .foregroundStyle(checked ? Theme.accent : Theme.muted)
            Text(String(change.code))
                .font(.system(size: 12, weight: .bold).monospaced())
                .foregroundStyle(color)
                .frame(width: 16)
            Text(change.originalPath.map { "\($0) → \(change.path)" } ?? change.path)
                .font(.system(size: 12).monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(diff).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 34)
        .background(Theme.rowFill, in: .rect(cornerRadius: 10, style: .continuous))
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(checked ? "inclus dans le commit" : "exclu du commit")
    }

    private var color: Color {
        switch change.code {
        case "?", "A": Tag.green.0
        case "D", "U": Theme.red
        default: Theme.orange
        }
    }

    private var diff: String {
        if change.isUntracked { return "nouveau" }
        if change.isConflict { return "conflit" }
        guard let added = change.added, let removed = change.removed else { return change.added == nil && change.removed == nil ? "" : "binaire" }
        return "+\(added) −\(removed)"
    }
}
