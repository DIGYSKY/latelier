import AppKit
import LAtelierCore
import SwiftUI

/// Projets › Dépôts : liste des dépôts à gauche, détail git à droite (maquette « Projets »).
struct ReposPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var filter: RepoFilter = .all

    var body: some View {
        let store = model.repos
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Projets", subtitle: subtitle) {
                Button(store.fetching ? "Fetch en cours…" : "Fetch de tous les dépôts", systemImage: "arrow.clockwise") {
                    model.fetchAll()
                }
                .buttonStyle(.secondary)
                .disabled(store.fetching || store.scanning || store.repos.isEmpty)
            }
            .padding(.top, 6)

            if model.projectRoots.isEmpty {
                Card {
                    EmptyState(symbol: "folder.badge.plus", title: "Aucun dossier de projets",
                               message: "Ajoutez vos dossiers depuis Stockage › Développement › Dossiers.")
                }
                Spacer()
            } else if store.scanning && store.repos.isEmpty {
                ScanningCard(label: "Recherche des dépôts git dans \(model.projectRoots.map { $0.abbreviatingHome() }.joined(separator: ", "))…")
                Spacer()
            } else if store.repos.isEmpty {
                Card { EmptyState(symbol: "arrow.triangle.branch", title: "Aucun dépôt git trouvé") }
                Spacer()
            } else {
                FilterChips(selection: $filter, counts: counts)
                HStack(alignment: .top, spacing: 14) {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(visible) { repo in
                                RepoCard(repo: repo, selected: repo.id == store.selected?.id, showParent: duplicateNames.contains(repo.name)) {
                                    store.selectedID = repo.id
                                }
                            }
                        }
                        .padding(.bottom, 20)
                    }
                    .scrollIndicators(.never)
                    .frame(width: 300)

                    if let repo = store.selected {
                        ScrollView {
                            RepoDetail(repo: repo).id(repo.id)
                                .padding(.bottom, 20)
                        }
                        .scrollIndicators(.automatic)
                    }
                }
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { Backdrop() }
        .onAppear { if store.stale && !store.scanning { model.scanRepos() } }
        .onChange(of: store.stale) { _, stale in if stale && !store.scanning { model.scanRepos() } }
    }

    private var subtitle: String {
        let store = model.repos
        if let message = store.message { return message }
        if store.scanning { return "Analyse des dépôts…" }
        let roots = model.projectRoots.map { $0.abbreviatingHome() }.joined(separator: " et ")
        return "\(store.repos.count) dépôt\(store.repos.count > 1 ? "s" : "") git dans \(roots)"
    }

    private var visible: [RepoStatus] { model.repos.repos.filter(filter.matches) }

    /// Noms portés par plusieurs dépôts : on affiche le dossier parent pour les distinguer.
    private var duplicateNames: Set<String> {
        Set(Dictionary(grouping: model.repos.repos, by: \.name).filter { $0.value.count > 1 }.keys)
    }

    private var counts: [RepoFilter: Int] {
        Dictionary(uniqueKeysWithValues: RepoFilter.allCases.map { f in (f, model.repos.repos.filter(f.matches).count) })
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
        .background(Color.white.opacity(0.5), in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.cardBorder))
    }
}

private struct RepoCard: View {
    let repo: RepoStatus
    let selected: Bool
    var showParent = false
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(repo.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if showParent {
                        Text(repo.url.deletingLastPathComponent().lastPathComponent)
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer()
                    if let date = repo.lastCommit?.date {
                        Text(RelativeDate.french(date)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                            .lineLimit(1).fixedSize()
                    }
                }
                HStack(spacing: 10) {
                    Text("⎇ \(repo.branch ?? "détaché")").font(.system(size: 12).monospaced()).lineLimit(1)
                    if let language = repo.languages.first { Text(language).font(.system(size: 12)) }
                    Spacer(minLength: 0)
                    StateLabel(repo: repo)
                }
                .foregroundStyle(Color.primary.opacity(0.8))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.raised : Color.white.opacity(0.5), in: .rect(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(selected ? Theme.accent.opacity(0.4) : Theme.cardBorder))
            .shadow(color: selected ? Theme.shadow.opacity(0.12) : .clear, radius: 7, y: 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
        case .behind: ("↓\(repo.behind) en retard", Color(hex: 0x0A4A99))
        case .noRemote: ("Sans remote", Theme.orange)
        case .noUpstream: ("Branche non publiée", Theme.orange)
        case .clean: ("À jour", Color(hex: 0x145C2A))
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
                            Text(commit.hash).font(.system(size: 12).monospaced()).foregroundStyle(Color(hex: 0x0A5BBF))
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
                Button("Terminal", systemImage: "terminal") { openTerminal() }.buttonStyle(.small)
                Button("Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([repo.url]) }
                    .buttonStyle(.small)
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

    /// Ouvre iTerm s'il est installé, sinon Terminal.
    private func openTerminal() {
        let workspace = NSWorkspace.shared
        guard let app = workspace.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2")
            ?? workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        workspace.open([repo.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
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
        .background(Color.white.opacity(0.6), in: .rect(cornerRadius: 10, style: .continuous))
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(checked ? "inclus dans le commit" : "exclu du commit")
    }

    private var color: Color {
        switch change.code {
        case "?", "A": Color(hex: 0x145C2A)
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
