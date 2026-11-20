import AppKit
import LAtelierCore
import SwiftUI

/// Performance › Processus : liste triable, regroupée par app ou à plat.
struct ProcessesPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var byApp = true
    @ViewState private var filter: ProcessFilter = .all
    @ViewState private var query = ""
    @ViewState private var sort: SortKey = .cpu
    @ViewState private var open: Set<String> = []
    @ViewState private var limit = 60

    enum SortKey: Hashable { case cpu, memory, threads, energy }

    var body: some View {
        let monitor = model.performance
        let projects = model.knownProjects
        let (rows, total) = makeRows(monitor.processes, projects: projects)
        PageScaffold(page: .processus, subtitle: summary(monitor)) {
            GlassSegments(selection: $byApp, items: [(true, String(localized: "Par app")), (false, String(localized: "Liste"))])
        } content: {
            HStack(spacing: 10) {
                GlassSegments(selection: $filter, items: [(.all, String(localized: "Tous")), (.mine, String(localized: "Mes processus")), (.dev, "Dev"), (.big, String(localized: "Gros consommateurs"))], compact: true)
                SearchField(prompt: String(localized: "Nom ou PID"), text: $query)
                Spacer()
                Button(monitor.paused ? String(localized: "Reprendre") : String(localized: "Mettre en pause")) { monitor.paused.toggle() }
                    .buttonStyle(.small)
            }
            if monitor.latest == nil {
                ScanningCard(label: String(localized: "Lecture des processus…"))
            } else {
                table(rows)
                HStack {
                    if total > limit {
                        Button(String(localized: "Afficher \(min(60, total - limit)) de plus")) { limit += 60 }.buttonStyle(.small)
                    }
                    Spacer()
                    Text(String(localized: "Processus du système et des autres comptes : lecture seule. Leur nombre de threads n’est pas lisible sans droits admin."))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
        }
        .onAppear {
            monitor.attach()
            model.ensureRepos()
        }
        .onDisappear { monitor.detach() }
        .onChange(of: filter) { limit = 60 }
        .onChange(of: query) { limit = 60 }
        .onChange(of: byApp) { limit = 60 }
    }

    private func summary(_ monitor: PerformanceMonitor) -> String {
        guard let sample = monitor.latest else { return String(localized: "Gestionnaire des tâches") }
        return String(localized: "\(monitor.processes.count) processus · CPU \(Format.percent(sample.cpu)) · mémoire \(Format.memory(sample.memory.used))")
    }

    // MARK: Lignes

    struct Row: Identifiable {
        var id: String
        var name: String
        var bundle: String?
        var project: URL?
        var cpu: Double
        var memory: Int64
        var threads: Int?
        var energy: EnergyImpact
        var user: String
        var count: Int
        var child = false
        var groupID: String?
        var targets: [ProcessTarget]
        var readOnly: Bool
        var path: String?
        var pid: Int32?
    }

    /// Lignes affichées (au plus `limit` groupes ou processus) et nombre total d'éléments.
    private func makeRows(_ processes: [RunningProcess], projects: [URL]) -> (rows: [Row], total: Int) {
        let q = query.lowercased()
        func matches(_ p: RunningProcess) -> Bool {
            q.isEmpty || p.displayName.lowercased().contains(q) || p.name.lowercased().contains(q) || String(p.pid) == q
        }
        if byApp {
            let groups = ProcessGroup.group(processes, projects: projects)
                .filter(filter.keeps)
                .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.processes.contains(where: matches) }
                .sorted(by: groupOrder)
            var rows: [Row] = []
            for group in groups.prefix(limit) {
                let first = group.processes[0]
                rows.append(Row(
                    id: group.id, name: group.processes.count > 1 ? "\(displayName(group)) (\(group.processes.count))" : displayName(group),
                    bundle: group.bundle, project: group.project, cpu: group.cpu, memory: group.memory, threads: group.threads,
                    energy: group.energy, user: first.userLabel, count: group.processes.count,
                    targets: group.quitTargets, readOnly: group.quitTargets.isEmpty, path: group.bundle ?? first.path,
                    pid: group.processes.count == 1 ? first.pid : nil
                ))
                if open.contains(group.id), group.processes.count > 1 {
                    for p in group.processes.sorted(by: processOrder) {
                        rows.append(Row(
                            id: "\(group.id)/\(p.pid)", name: "\(p.name) · \(p.pid)", bundle: nil, project: nil, cpu: p.cpu,
                            memory: p.memory, threads: p.threads, energy: p.energy, user: p.userLabel, count: 1, child: true,
                            groupID: group.id, targets: p.canQuit ? [p.target] : [], readOnly: !p.canQuit, path: p.path, pid: p.pid
                        ))
                    }
                }
            }
            return (rows, groups.count)
        }
        let list = processes
            .filter { filter.keeps($0, projects: projects) }
            .filter(matches)
            .sorted(by: processOrder)
            .map { p in
                Row(
                    id: String(p.pid), name: "\(p.displayName) · \(p.pid)", bundle: p.appBundle,
                    project: p.cwd.flatMap { ProjectMatcher.project(for: $0, in: projects) }, cpu: p.cpu, memory: p.memory,
                    threads: p.threads, energy: p.energy, user: p.userLabel, count: 1,
                    targets: p.canQuit ? [p.target] : [], readOnly: !p.canQuit, path: p.path, pid: p.pid
                )
            }
        return (Array(list.prefix(limit)), list.count)
    }

    private func displayName(_ group: ProcessGroup) -> String {
        group.bundle == nil ? group.processes[0].displayName : group.name
    }

    private func groupOrder(_ a: ProcessGroup, _ b: ProcessGroup) -> Bool {
        switch sort {
        case .cpu: a.cpu > b.cpu
        case .memory: a.memory > b.memory
        case .threads: (a.threads ?? -1) > (b.threads ?? -1)
        case .energy: (a.energy, a.cpu) > (b.energy, b.cpu)
        }
    }

    private func processOrder(_ a: RunningProcess, _ b: RunningProcess) -> Bool {
        switch sort {
        case .cpu: a.cpu > b.cpu
        case .memory: a.memory > b.memory
        case .threads: (a.threads ?? -1) > (b.threads ?? -1)
        case .energy: (a.energy, a.cpu) > (b.energy, b.cpu)
        }
    }

    // MARK: Tableau

    private func table(_ shown: [Row]) -> some View {
        LazyVStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(String(localized: "Processus")).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 18)
                SortHeader(label: "% CPU", active: sort == .cpu) { sort = .cpu }.frame(width: 90, alignment: .leading)
                SortHeader(label: String(localized: "Mémoire"), active: sort == .memory) { sort = .memory }.frame(width: 96, alignment: .leading)
                SortHeader(label: "Threads", active: sort == .threads) { sort = .threads }.frame(width: 86, alignment: .leading)
                SortHeader(label: String(localized: "Énergie"), active: sort == .energy) { sort = .energy }.frame(width: 90, alignment: .leading)
                Text(String(localized: "Utilisateur")).frame(width: 90, alignment: .leading)
                Color.clear.frame(width: 104)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.muted)
            .padding(.vertical, 6)

            if shown.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: String(localized: "Aucun processus ne correspond"))
            }
            ForEach(shown) { row in
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ProcessRow(row: row, open: open.contains(row.id)) {
                    withAnimation(.snappy(duration: 0.2)) {
                        if open.contains(row.id) { open.remove(row.id) } else { open.insert(row.id) }
                    }
                }
            }
        }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .cardBackground()
    }
}

private struct ProcessRow: View {
    @Environment(AppModel.self) private var model
    let row: ProcessesPage.Row
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                if row.count > 1 {
                    Button(action: toggle) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.muted)
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: 18, height: 24)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(open ? String(localized: "Replier \(row.name)") : String(localized: "Déplier \(row.name)"))
                } else {
                    Color.clear.frame(width: 18)
                }
                if row.child {
                    Circle().fill(Theme.hairline).frame(width: 8, height: 8).frame(width: 20)
                } else {
                    ProcessIcon(name: row.name, bundle: row.bundle)
                }
                Text(row.name)
                    .font(.system(size: 13, weight: row.child ? .regular : .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let project = row.project {
                    Button(project.lastPathComponent) { model.showRepository(project) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Theme.accent.opacity(0.12), in: .capsule)
                        .help(String(localized: "Lancé depuis \(project.abbreviatingHome())"))
                }
            }
            .padding(.leading, row.child ? 40 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(Format.percent(row.cpu, decimals: 1))
                .font(.system(size: 13, weight: row.child ? .regular : .semibold)).monospacedDigit()
                .foregroundStyle(row.cpu > 30 ? Tag.red.0 : .primary)
                .frame(width: 90, alignment: .leading).padding(.leading, 8)
            Text(Format.memory(row.memory)).font(.system(size: 13)).monospacedDigit()
                .frame(width: 96, alignment: .leading).padding(.leading, 8)
            Text(row.threads.map(String.init) ?? "—").font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.muted)
                .frame(width: 86, alignment: .leading).padding(.leading, 8)
            Text(row.energy.label).font(.system(size: 13)).foregroundStyle(row.energy == .high ? Tag.orange.0 : Theme.muted)
                .frame(width: 90, alignment: .leading).padding(.leading, 8)
            Text(row.user).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                .frame(width: 90, alignment: .leading)
            Group {
                if !row.targets.isEmpty && !row.child {
                    Button(String(localized: "Quitter")) { model.quit(row.targets, label: label, force: false) }
                        .buttonStyle(.small)
                } else if row.readOnly && !row.child {
                    Text("lecture seule").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            .frame(width: 104, alignment: .trailing)
            .padding(.trailing, 18)
        }
        .frame(minHeight: 36)
        .background(row.child ? Theme.raised.opacity(0.35) : .clear)
        .contentShape(.rect)
        .onTapGesture(count: 2) { if let pid = row.pid { model.processDetail = ProcessDetailRequest(pid: pid) } }
        .contextMenu { menu }
    }

    private var label: String {
        row.name.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
    }

    @ViewBuilder
    private var menu: some View {
        if let pid = row.pid {
            Button(String(localized: "Détails…")) { model.processDetail = ProcessDetailRequest(pid: pid) }
            Divider()
        }
        if !row.targets.isEmpty {
            Button(String(localized: "Quitter")) { model.quit(row.targets, label: label, force: false) }
            Button(String(localized: "Forcer à quitter…")) { model.quit(row.targets, label: label, force: true) }
            Divider()
        }
        if let path = row.path {
            Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
        if let project = row.project {
            Button(String(localized: "Ouvrir le projet \(project.lastPathComponent)")) { model.showRepository(project) }
        }
        if let pid = row.pid {
            Button(String(localized: "Copier le PID")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(pid), forType: .string)
            }
        }
    }
}
