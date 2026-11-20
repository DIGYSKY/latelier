import LAtelierCore
import SwiftUI

/// Performance › Vue d'ensemble : ressources en temps réel, gros consommateurs, ports en écoute.
struct PerformancePage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var filter: ProcessFilter = .all
    @ViewState private var query = ""
    @ViewState private var sortByMemory = false
    @ViewState private var selected: Int32?

    var body: some View {
        let monitor = model.performance
        PageScaffold(page: .perfVue, subtitle: subtitle(monitor)) {
            Button(monitor.paused ? String(localized: "Reprendre") : String(localized: "Mettre en pause")) { monitor.paused.toggle() }
                .buttonStyle(.secondary)
        } content: {
            if let sample = monitor.latest {
                tiles(sample, monitor)
                HStack(alignment: .top, spacing: 14) {
                    processes(monitor)
                    PortsCard(ports: monitor.ports, monitor: monitor)
                        .frame(width: 280)
                }
            } else {
                ScanningCard(label: String(localized: "Première mesure…"))
            }
        }
        .onAppear {
            monitor.attach()
            model.ensureRepos()
        }
        .onDisappear { monitor.detach() }
    }

    private func subtitle(_ monitor: PerformanceMonitor) -> String {
        let m = monitor.machine
        let cores = m.efficiencyCores > 0 ? String(localized: "\(m.cores) cœurs (\(m.performanceCores) perf. + \(m.efficiencyCores) eff.)") : String(localized: "\(m.cores) cœurs")
        var parts = [m.chip, cores, Format.memory(m.memory).replacingOccurrences(of: ",0", with: "")]
        if let power = monitor.latest?.power { parts.append(energyDetail(power)) }
        parts.append(monitor.paused ? String(localized: "en pause") : String(localized: "mis à jour chaque seconde"))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func tiles(_ s: SystemSample, _ monitor: PerformanceMonitor) -> some View {
        let memory = s.memory
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
            MetricTile(
                label: String(localized: "Processeur"), value: Format.percent(s.cpu),
                detail: monitor.machine.efficiencyCores > 0
                    ? String(localized: "Perf. \(Format.percent(s.performanceLoad)) · Eff. \(Format.percent(s.efficiencyLoad))")
                    : String(localized: "\(s.cores.count) cœurs"),
                history: monitor.cpuHistory, maxValue: 100
            )
            MetricTile(
                label: String(localized: "Mémoire"),
                value: "\(Format.decimal(Double(memory.used) / 1_073_741_824)) / \(Format.memory(memory.total).replacingOccurrences(of: ",0", with: ""))",
                detail: String(localized: "Pression \(memory.pressure.label) · swap \(Format.memory(memory.swapUsed))"),
                detailColor: pressureColor(memory.pressure), detailBold: true,
                history: monitor.memoryHistory, maxValue: Double(memory.total)
            )
            .help(String(localized: "Apps \(Format.memory(memory.app)) · résidente \(Format.memory(memory.wired)) · compressée \(Format.memory(memory.compressed)) · fichiers en cache \(Format.memory(memory.cached))"))
            if let gpu = s.gpu {
                MetricTile(
                    label: "GPU", value: Format.percent(gpu.utilization),
                    detail: gpu.memoryInUse.map { String(localized: "Mémoire GPU \(Format.memory($0))") } ?? String(localized: "Mémoire partagée"),
                    history: monitor.gpuHistory, maxValue: 100
                )
            }
            MetricTile(
                label: String(localized: "Réseau"), value: "↓ \(Format.rate(s.networkIn))",
                detail: "↑ \(Format.rate(s.networkOut))" + (s.network.primaryName.map { " · \($0)" } ?? ""),
                history: monitor.networkHistory
            )
            MetricTile(
                label: String(localized: "Disque"), value: Format.rate(s.diskRead + s.diskWrite),
                detail: String(localized: "Lecture + écriture") + (s.diskFree.map { String(localized: " · \($0 / 1_000_000_000) Go libres") } ?? ""),
                history: monitor.diskHistory
            )
        }
    }

    private func energyDetail(_ power: PowerSnapshot) -> String {
        let thermal = power.thermal == .nominal ? "" : String(localized: " · température \(power.thermalLabel)")
        guard let level = power.batteryLevel else { return "secteur" + thermal }
        let state = power.charging ? String(localized: " en charge") : power.onBattery ? "" : String(localized: " · branché")
        return String(localized: "batterie \(level) %\(state)") + thermal
    }

    private func pressureColor(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: Tag.green.0
        case .warning: Tag.orange.0
        case .critical: Tag.red.0
        }
    }

    // MARK: Processus

    private func processes(_ monitor: PerformanceMonitor) -> some View {
        let projects = model.knownProjects
        let q = query.lowercased()
        let list = monitor.processes
            .filter { filter.keeps($0, projects: projects) }
            .filter { q.isEmpty || $0.displayName.lowercased().contains(q) || String($0.pid) == q }
            .sorted { sortByMemory ? $0.memory > $1.memory : $0.cpu > $1.cpu }
            .prefix(12)
        let selection = selected.flatMap(monitor.process)

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                GlassSegments(selection: $filter, items: [(.all, String(localized: "Tous")), (.dev, "Dev"), (.big, String(localized: "Gros consommateurs"))], compact: true)
                SearchField(prompt: String(localized: "Rechercher"), text: $query)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack(spacing: 0) {
                Text(String(localized: "Processus")).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 14)
                Text("PID").frame(width: 62, alignment: .leading)
                SortHeader(label: "% CPU", active: !sortByMemory) { sortByMemory = false }.frame(width: 84, alignment: .leading)
                SortHeader(label: String(localized: "Mémoire"), active: sortByMemory) { sortByMemory = true }.frame(width: 92, alignment: .leading)
                Text(String(localized: "Réseau")).frame(width: 86, alignment: .leading)
                Text(String(localized: "Projet")).frame(width: 110, alignment: .leading)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.muted)
            .padding(.vertical, 4)

            ForEach(Array(list)) { process in
                Rectangle().fill(Theme.hairline).frame(height: 1)
                OverviewRow(process: process, project: process.cwd.flatMap { ProjectMatcher.project(for: $0, in: projects) },
                            rate: monitor.traffic[process.pid], selected: selected == process.pid) {
                    selected = selected == process.pid ? nil : process.pid
                }
            }
            if list.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: String(localized: "Aucun processus ne correspond"))
            }
            if let selection {
                SelectionBar(process: selection, project: selection.cwd.flatMap { ProjectMatcher.project(for: $0, in: projects) })
            }
        }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .cardBackground()
        .frame(maxWidth: .infinity)
    }
}

/// Filtres communs à la vue d'ensemble et à Processus.
enum ProcessFilter: Hashable {
    case all, mine, dev, big

    func keeps(_ process: RunningProcess, projects: [URL]) -> Bool {
        switch self {
        case .all: true
        case .mine: process.isMine
        case .dev: process.isDev || process.cwd.flatMap { ProjectMatcher.project(for: $0, in: projects) } != nil
        case .big: process.cpu >= 10 || process.memory >= 1 << 30
        }
    }

    func keeps(_ group: ProcessGroup) -> Bool {
        switch self {
        case .all: true
        case .mine: group.isMine
        case .dev: group.isDev
        case .big: group.cpu >= 10 || group.memory >= 1 << 30
        }
    }
}

private struct OverviewRow: View {
    @Environment(AppModel.self) private var model
    let process: RunningProcess
    let project: URL?
    let rate: TrafficSampler.Rate?
    let selected: Bool
    let select: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                ProcessIcon(name: process.displayName, bundle: process.appBundle)
                Text(process.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if process.isSystem {
                    Text(String(localized: "système"))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.hairline))
                }
            }
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)
            Text(String(process.pid)).font(.system(size: 12).monospaced()).foregroundStyle(Theme.muted).frame(width: 62, alignment: .leading)
            Text(Format.percent(process.cpu, decimals: 1))
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(process.cpu > 30 ? Tag.red.0 : .primary)
                .frame(width: 84, alignment: .leading).padding(.leading, 8)
            Text(Format.memory(process.memory)).font(.system(size: 13)).monospacedDigit().frame(width: 92, alignment: .leading).padding(.leading, 8)
            Text(rate.map { Format.rate($0.down + $0.up) } ?? "—")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit().lineLimit(1)
                .frame(width: 86, alignment: .leading)
            Group {
                if let project {
                    Button(project.lastPathComponent) { model.showRepository(project) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .help(project.abbreviatingHome())
                } else {
                    Text("")
                }
            }
            .frame(width: 110, alignment: .leading)
        }
        .frame(minHeight: 34)
        .background(selected ? Theme.accent.opacity(0.12) : .clear)
        .contentShape(.rect)
        .onTapGesture(count: 2) { model.processDetail = ProcessDetailRequest(pid: process.pid) }
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Barre d'actions du processus sélectionné.
private struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    let process: RunningProcess
    let project: URL?

    var body: some View {
        HStack(spacing: 10) {
            (Text(process.displayName).bold()
                + Text(String(localized: " · PID \(String(process.pid))") + (project.map { String(localized: " · lancé depuis \($0.lastPathComponent)") } ?? "")).foregroundStyle(Theme.muted))
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer()
            Button(String(localized: "Détails…")) { model.processDetail = ProcessDetailRequest(pid: process.pid) }
                .buttonStyle(.small)
            if process.canQuit {
                Button(String(localized: "Quitter")) { model.quit([process.target], label: process.displayName, force: false) }
                    .buttonStyle(.small)
                Button(String(localized: "Forcer à quitter…")) { model.quit([process.target], label: process.displayName, force: true) }
                    .buttonStyle(.small)
                    .foregroundStyle(Tag.red.0)
            } else {
                Text(process.isMine ? String(localized: "Processus système : lecture seule") : String(localized: "Processus d’un autre compte : lecture seule"))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.raised.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// Carte « Ports en écoute » de la vue d'ensemble.
private struct PortsCard: View {
    @Environment(AppModel.self) private var model
    let ports: [ListeningPort]
    let monitor: PerformanceMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Ports en écoute").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(String(localized: "Tout voir")) { model.selection = .reseau }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            if ports.isEmpty {
                Text("Aucun port ouvert par vos processus.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            ForEach(PortDescriber.sorted(ports).prefix(8)) { port in
                let info = PortDescriber(model: model, monitor: monitor).describe(port)
                HStack(spacing: 10) {
                    Text(":\(String(port.port))").font(.system(size: 13, weight: .bold).monospaced()).frame(minWidth: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(info.process).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            .help(String(localized: "\(info.process) · PID \(String(port.pid))"))
                        Text(info.note).font(.system(size: 11)).foregroundStyle(port.exposed ? Tag.orange.0 : Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    PortActions(port: port, compact: true).fixedSize()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.raised.opacity(0.6), in: .rect(cornerRadius: 12, style: .continuous))
                .portContextMenu(port)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

/// Décrit un port : quel processus, quel projet / service / app.
struct PortDescriber {
    let model: AppModel
    let monitor: PerformanceMonitor

    struct Info { var process: String; var note: String; var project: URL? }

    /// Ports de dev d'abord (les plus utiles), puis par numéro.
    static func sorted(_ ports: [ListeningPort]) -> [ListeningPort] {
        ports.sorted { a, b in
            let da = a.port < 10000, db = b.port < 10000
            return da != db ? da : a.port < b.port
        }
    }

    func describe(_ port: ListeningPort, withScope: Bool = true) -> Info {
        let process = monitor.process(port.pid)
        let name = process?.displayName ?? port.command
        var parts: [String] = []
        let project = process?.cwd.flatMap { ProjectMatcher.project(for: $0, in: model.knownProjects) }
        if let project { parts.append(project.lastPathComponent) }
        if let service = model.services.value?.first(where: { $0.pid == port.pid }) {
            parts.append(String(localized: "Services › \(service.name)"))
        } else if project == nil, let bundle = process?.appBundle {
            let app = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
            if app != name { parts.append(app) }
        }
        if withScope { parts.append(port.exposed ? String(localized: "exposé au réseau local") : String(localized: "local uniquement")) }
        if parts.isEmpty { parts.append(process?.path.map { ($0 as NSString).deletingLastPathComponent } ?? "") }
        return Info(process: name, note: parts.joined(separator: " · "), project: project)
    }
}
