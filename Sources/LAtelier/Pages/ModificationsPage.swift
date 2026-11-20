import LAtelierCore
import SwiftUI

/// Projets › Modifications : tout ce qui n'est pas commité, pas poussé ou en retard,
/// tous dépôts confondus.
struct ModificationsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.repos
        PageScaffold(page: .modifications, subtitle: store.message ?? summary) {
            Button(store.fetching ? "Fetch en cours…" : "Fetch de tous les dépôts", systemImage: "arrow.clockwise") {
                model.fetchAll()
            }
            .buttonStyle(.secondary)
            .disabled(store.fetching || store.scanning || store.repos.isEmpty)
            Button("Pousser tout (\(pushable.count))", systemImage: "arrow.up") { pushAll() }
                .buttonStyle(.primary)
                .disabled(pushable.isEmpty)
        } content: {
            if store.scanning && store.repos.isEmpty {
                ScanningCard(label: "Analyse des dépôts…")
            } else if groups.isEmpty {
                Card { EmptyState(symbol: "checkmark.circle", title: "Tout est à jour", message: "Aucun dépôt n’a de modification, de commit à pousser ou de retard.") }
            } else {
                ForEach(groups, id: \.title) { group in
                    RepoGroupCard(title: group.title, detail: group.detail, repos: group.repos)
                }
            }
        }
        .onAppear { if store.stale && !store.scanning { model.scanRepos() } }
        .onChange(of: store.stale) { _, stale in if stale && !store.scanning { model.scanRepos() } }
    }

    private var repos: [RepoStatus] { model.repos.repos }

    private var groups: [(title: String, detail: String, repos: [RepoStatus])] {
        [
            ("Opération en cours ou conflit", "À terminer dans le terminal", repos.filter { $0.state == .conflict }),
            ("Modifications non commitées", "Fichiers modifiés ou nouveaux", repos.filter { $0.state == .modified }),
            ("Historiques divergés", "Ni pull ni push en avance rapide : à régler à la main", repos.filter { $0.state == .diverged }),
            ("Commits à pousser", "Pas encore sur le distant", repos.filter { $0.canPush && $0.state != .modified }),
            ("En retard sur le distant", "Un pull les met à jour", repos.filter { $0.state == .behind }),
            ("Sans remote", "Sauvegardés nulle part", repos.filter { $0.state == .noRemote }),
        ].filter { !$0.2.isEmpty }
    }

    private var pushable: [RepoStatus] { repos.filter(\.canPush) }

    private var summary: String {
        let modified = repos.filter { !$0.changes.isEmpty }.count
        let ahead = pushable.count
        let behind = repos.filter { $0.behind > 0 }.count
        return "\(modified) modifié\(modified > 1 ? "s" : "") · \(ahead) à pousser · \(behind) en retard, sur \(repos.count) dépôts"
    }

    private func pushAll() {
        let steps = pushable.compactMap { GitClient.pushPlan($0)?.steps.first }
        model.preview(ActionPlan(
            title: "Pousser \(steps.count) dépôt(s)",
            summary: "Un push par dépôt, jamais forcé. Si l’un échoue, les autres continuent.",
            kind: .git, risk: .safe, reversible: false, steps: steps, stopOnFailure: false
        ))
    }
}

private struct RepoGroupCard: View {
    @Environment(AppModel.self) private var model
    let title: String
    let detail: String
    let repos: [RepoStatus]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Text("\(repos.count)").font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Theme.headerFill)

            ForEach(repos) { repo in
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo.name).font(.system(size: 14, weight: .semibold))
                        Text("\(repo.url.abbreviatingHome()) · ⎇ \(repo.branch ?? "détaché")")
                            .font(.system(size: 12).monospaced())
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    StateLabel(repo: repo).frame(width: 150, alignment: .leading)
                    actions(for: repo)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .frame(minHeight: 52)
            }
        }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .cardBackground()
    }

    @ViewBuilder
    private func actions(for repo: RepoStatus) -> some View {
        HStack(spacing: 6) {
            if repo.operationInProgress == nil {
                if repo.behind > 0 && repo.ahead == 0 {
                    Button("Pull ↓\(repo.behind)") { model.preview(GitClient.pullPlan(repo)) }.buttonStyle(.small)
                }
                if repo.ahead > 0 && repo.behind == 0 || repo.state == .noUpstream, let plan = GitClient.pushPlan(repo) {
                    Button(repo.upstream == nil ? "Publier" : "Push ↑\(repo.ahead)") { model.preview(plan) }.buttonStyle(.small)
                }
            }
            Button("Ouvrir") {
                model.repos.selectedID = repo.id
                model.selection = .depots
            }
            .buttonStyle(.small)
        }
        .frame(width: 210, alignment: .trailing)
    }
}
