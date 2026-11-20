import AppKit
import Charts
import LAtelierCore
import SwiftUI

// MARK: - Ports : ouvrir, copier

/// Vérifie si un port local répond en HTTP (requête vers localhost seulement, jamais vers l'extérieur).
@Observable
final class PortProbe {
    static let shared = PortProbe()
    private(set) var http: [Int: Bool] = [:]
    @ObservationIgnored private var checked: [Int: Date] = [:]

    func check(_ port: Int) {
        if let last = checked[port], Date().timeIntervalSince(last) < 30 { return }
        checked[port] = Date()
        guard let url = URL(string: "http://localhost:\(port)/") else { return }
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.httpMethod = "HEAD"
        Task {
            // Une vraie réponse HTTP a des en-têtes (une base de données ou un autre protocole n'en renvoie pas).
            let ok = (try? await URLSession.shared.data(for: request)).map { response in
                guard let http = response.1 as? HTTPURLResponse else { return false }
                return (100..<600).contains(http.statusCode) && !http.allHeaderFields.isEmpty
            } ?? false
            http[port] = ok
        }
    }

    static func address(_ port: Int, http: Bool) -> String { http ? "http://localhost:\(port)" : "localhost:\(port)" }
}

/// Boutons d'un port en écoute : ouvrir dans le navigateur (si HTTP), copier l'adresse.
struct PortActions: View {
    let port: ListeningPort
    private var probe: PortProbe { .shared }

    var body: some View {
        let http = probe.http[port.port] == true
        HStack(spacing: 6) {
            if http {
                Button {
                    if let url = URL(string: PortProbe.address(port.port, http: true)) { NSWorkspace.shared.open(url) }
                } label: { Label("Ouvrir", systemImage: "safari").fixedSize() }
                    .buttonStyle(PillButtonStyle(kind: .small))
                    .help("Ouvrir http://localhost:\(port.port) dans le navigateur")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(PortProbe.address(port.port, http: http), forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(PillButtonStyle(kind: .small))
                .help("Copier \(PortProbe.address(port.port, http: http))")
                .accessibilityLabel("Copier l’adresse")
        }
        .onAppear { probe.check(port.port) }
    }
}

extension View {
    /// Menu contextuel d'un port : ouvrir, copier l'adresse, copier le PID.
    func portContextMenu(_ port: ListeningPort) -> some View {
        contextMenu {
            let http = PortProbe.shared.http[port.port] == true
            if http, let url = URL(string: PortProbe.address(port.port, http: true)) {
                Button("Ouvrir \(url.absoluteString)") { NSWorkspace.shared.open(url) }
            }
            Button("Copier \(PortProbe.address(port.port, http: http))") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(PortProbe.address(port.port, http: http), forType: .string)
            }
            Button("Copier le PID (\(port.pid))") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(port.pid), forType: .string)
            }
        }
    }
}

// MARK: - Fiche d'un processus

struct ProcessDetailRequest: Identifiable {
    let pid: Int32
    var id: Int32 { pid }
}

/// Tout sur un processus : performances en direct, identité, arborescence, réseau, actions.
struct ProcessDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pid: Int32
    @ViewState private var arguments: [String]?
    @ViewState private var signer: Signer?
    @ViewState private var children: [Int32] = []
    @ViewState private var last: RunningProcess?

    var body: some View {
        let monitor = model.performance
        let process = monitor.process(pid) ?? last
        VStack(spacing: 0) {
            if let process {
                header(process)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if monitor.process(pid) == nil {
                            Label("Ce processus s’est terminé.", systemImage: "xmark.octagon").foregroundStyle(Theme.red)
                        }
                        performance(process, monitor: monitor)
                        identity(process)
                        tree(process, monitor: monitor)
                        network(process, monitor: monitor)
                    }
                    .padding(20)
                }
            } else {
                ProgressView("Lecture du processus \(pid)…").padding(40)
            }
        }
        .frame(width: 760, height: 680)
        .onAppear {
            monitor.attach()
            arguments = ProcessTree.arguments(of: pid)
            children = ProcessTree.descendants(of: pid)
            // La signature d'une app se lit sur le paquet .app, pas sur l'exécutable.
            if let process = monitor.process(pid), let path = process.appBundle ?? process.path { signer = Signer.of(path: path) }
        }
        .onDisappear { monitor.detach() }
        .onChange(of: monitor.process(pid)) { _, new in if let new { last = new } }
    }

    private func header(_ process: RunningProcess) -> some View {
        HStack(spacing: 12) {
            ProcessIcon(name: process.displayName, bundle: process.appBundle).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(process.displayName).font(.system(size: 19, weight: .bold))
                Text("PID \(process.pid) · \(process.userLabel) · \(process.energy == .high ? "impact énergétique élevé" : "impact énergétique \(energyLabel(process.energy))")")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if process.canQuit {
                Button("Quitter") {
                    dismiss()
                    model.quit([process.target], label: process.displayName, force: false)
                }
                .buttonStyle(PillButtonStyle(kind: .small))
                Button("Forcer") {
                    dismiss()
                    model.quit([process.target], label: process.displayName, force: true)
                }
                .buttonStyle(PillButtonStyle(kind: .small))
            }
            Button("Fermer") { dismiss() }
                .buttonStyle(PillButtonStyle(kind: .smallFilled))
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private func energyLabel(_ impact: EnergyImpact) -> String {
        switch impact {
        case .none: "nul"
        case .low: "faible"
        case .medium: "moyen"
        case .high: "élevé"
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(radius: 18)
    }

    private func performance(_ process: RunningProcess, monitor: PerformanceMonitor) -> some View {
        let history = monitor.processHistory[pid] ?? []
        return section("Performances (2 dernières minutes)") {
            HStack(spacing: 10) {
                StatTile(label: "Processeur", value: Format.percent(process.cpu))
                StatTile(label: "Mémoire", value: Format.bytes(process.memory))
                StatTile(label: "Threads", value: process.threads.map(String.init) ?? "—")
                StatTile(label: "Réveils / s", value: Format.decimal(process.wakeups, decimals: 0))
            }
            HStack(spacing: 14) {
                chart("Processeur (%)", values: history.map(\.cpu), color: Theme.accent) { Format.percent($0) }
                chart("Mémoire", values: history.map { Double($0.memory) }, color: Color(hex: 0x6E4BD8)) { Format.bytes(Int64($0)) }
            }
            .frame(height: 150)
            HStack(spacing: 10) {
                StatTile(label: "Lu sur le disque", value: Format.bytes(Int64(process.diskRead)))
                StatTile(label: "Écrit sur le disque", value: Format.bytes(Int64(process.diskWritten)))
                if let rate = monitor.traffic[pid] {
                    StatTile(label: "Réseau ↓ / ↑", value: "\(Format.rate(rate.down)) / \(Format.rate(rate.up))")
                }
            }
        }
    }

    private func chart(_ title: String, values: [Double], color: Color, format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                Spacer()
                if let max = values.max() { Text("max \(format(max))").font(.system(size: 11)).foregroundStyle(Theme.muted) }
            }
            Chart(Array(values.enumerated()), id: \.offset) { point in
                AreaMark(x: .value("t", point.offset), y: .value("v", point.element))
                    .foregroundStyle(color.opacity(0.2))
                LineMark(x: .value("t", point.offset), y: .value("v", point.element))
                    .foregroundStyle(color)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text(format(v)).font(.system(size: 9)) } }
                }
            }
        }
        .padding(10)
        .background(Theme.raised.opacity(0.5), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private func identity(_ process: RunningProcess) -> some View {
        section("Identité") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                row("Exécutable", process.path ?? "inconnu (processus d’un autre compte)", mono: true)
                if let arguments, arguments.count > 1 {
                    row("Arguments", RecorderDetector.displayCommand(arguments), mono: true)
                }
                if let cwd = process.cwd { row("Dossier de travail", cwd, mono: true) }
                if let project = process.cwd.flatMap({ ProjectMatcher.project(for: $0, in: model.knownProjects) }) {
                    row("Projet", model.projectName(project), mono: false)
                }
                let start = Date(timeIntervalSince1970: TimeInterval(process.started))
                row("Démarré", start.formatted(date: .abbreviated, time: .standard) + " · depuis " + Self.uptime(Date().timeIntervalSince(start)), mono: false)
                row("Utilisateur", process.userLabel, mono: false)
                if let signer {
                    row("Signature", signer.apple ? "Apple" : (signer.name ?? "signé") + (signer.teamID.map { " (\($0))" } ?? ""), mono: false)
                } else if process.path != nil {
                    row("Signature", "non signé ou illisible", mono: false)
                }
            }
            HStack(spacing: 8) {
                if let path = process.path {
                    Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        .buttonStyle(PillButtonStyle(kind: .small))
                }
                Button("Copier la commande") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString((arguments ?? [process.path ?? process.name]).joined(separator: " "), forType: .string)
                }
                .buttonStyle(PillButtonStyle(kind: .small))
                if let cwd = process.cwd {
                    Button("Ouvrir le dossier dans le terminal") { model.openTerminal(URL(fileURLWithPath: cwd)) }
                        .buttonStyle(PillButtonStyle(kind: .small))
                }
            }
        }
    }

    /// « 2 j 2 h », « 3 h 12 min », « 45 s ».
    static func uptime(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86_400 { return "\(s / 3600) h \(s % 3600 / 60) min" }
        return "\(s / 86_400) j \(s % 86_400 / 3600) h"
    }

    private func row(_ label: String, _ value: String, mono: Bool) -> some View {
        GridRow {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted).gridColumnAlignment(.leading)
            Text(value).font(mono ? .system(size: 12).monospaced() : .system(size: 13))
                .lineLimit(3).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private func tree(_ process: RunningProcess, monitor: PerformanceMonitor) -> some View {
        let parent = monitor.process(process.ppid)
        let kids = children.compactMap(monitor.process).sorted { $0.cpu > $1.cpu }
        return section("Arborescence") {
            HStack {
                Text("Parent").font(.system(size: 12)).foregroundStyle(Theme.muted)
                if let parent {
                    Button("\(parent.displayName) (PID \(parent.pid))") { model.processDetail = ProcessDetailRequest(pid: parent.pid) }
                        .buttonStyle(.link)
                } else {
                    Text("PID \(process.ppid)").font(.system(size: 13))
                }
            }
            if kids.isEmpty {
                Text("Aucun processus enfant.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            } else {
                Text("\(kids.count) processus enfant\(kids.count > 1 ? "s" : "") · \(Format.percent(kids.reduce(0) { $0 + $1.cpu })) CPU · \(Format.bytes(kids.reduce(0) { $0 + $1.memory }))")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                ForEach(kids.prefix(12)) { child in
                    HStack {
                        Button(child.displayName) { model.processDetail = ProcessDetailRequest(pid: child.pid) }.buttonStyle(.link)
                        Text("PID \(child.pid)").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        Spacer()
                        Text(Format.percent(child.cpu)).monospacedDigit().frame(width: 60, alignment: .trailing)
                        Text(Format.bytes(child.memory)).monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                    .font(.system(size: 12))
                }
            }
        }
    }

    private func network(_ process: RunningProcess, monitor: PerformanceMonitor) -> some View {
        let ports = monitor.ports.filter { $0.pid == pid }
        let connections = monitor.connections[pid]
        return section("Réseau") {
            if ports.isEmpty && connections == nil {
                Text("Aucun port ouvert ni connexion établie.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            ForEach(ports) { port in
                HStack {
                    Text(":\(String(port.port))").font(.system(size: 13, weight: .bold).monospaced())
                    Text(port.displayAddress).font(.system(size: 12).monospaced()).foregroundStyle(Theme.muted)
                    if port.exposed { Tag(text: "Exposé au réseau local", foreground: Tag.orange.0, background: Tag.orange.1) }
                    Spacer()
                    PortActions(port: port)
                }
                .portContextMenu(port)
            }
            if let connections {
                Text("\(connections.count) connexion\(connections.count > 1 ? "s" : "") établie\(connections.count > 1 ? "s" : "")"
                     + (connections.hosts.isEmpty ? "" : " · " + connections.hosts.prefix(6).joined(separator: ", ")))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).textSelection(.enabled)
            }
        }
    }
}

// MARK: - Moniteur : les performances en grand

struct MonitorPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let monitor = model.performance
        PageScaffold(page: .moniteur, subtitle: "\(monitor.machine.chip) · 5 dernières minutes, une mesure par seconde") {
            Button(monitor.paused ? "Reprendre" : "Pause", systemImage: monitor.paused ? "play.fill" : "pause.fill") { monitor.paused.toggle() }
                .buttonStyle(.secondary)
        } content: {
            if let sample = monitor.latest {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    BigChart(title: "Processeur", value: Format.percent(sample.cpu),
                             detail: "Performance \(Format.percent(sample.performanceLoad)) · Efficacité \(Format.percent(sample.efficiencyLoad))",
                             series: [("Total", monitor.cpuHistory, Theme.accent)], format: { Format.percent($0) }, maximum: 100)
                    BigChart(title: "Mémoire", value: Format.bytes(sample.memory.used),
                             detail: "sur \(Format.bytes(sample.memory.total)) · pression \(sample.memory.pressure.label) · swap \(Format.bytes(sample.memory.swapUsed))",
                             series: [("Utilisée", monitor.memoryHistory, Color(hex: 0x6E4BD8))], format: { Format.bytes(Int64($0)) },
                             maximum: Double(sample.memory.total))
                    BigChart(title: "Disque", value: "\(Format.rate(sample.diskRead)) ↓  \(Format.rate(sample.diskWrite)) ↑",
                             detail: sample.diskFree.map { "\(Format.bytes($0)) libres" } ?? "lecture et écriture",
                             series: [("Lecture", monitor.diskReadHistory, Color(hex: 0x00879E)), ("Écriture", monitor.diskWriteHistory, Color(hex: 0xE8890C))],
                             format: { Format.rate($0) })
                    BigChart(title: "Réseau", value: "\(Format.rate(sample.networkIn)) ↓  \(Format.rate(sample.networkOut)) ↑",
                             detail: sample.network.primaryName ?? "réception et envoi",
                             series: [("Reçu", monitor.netInHistory, Color(hex: 0x1E8A45)), ("Envoyé", monitor.netOutHistory, Color(hex: 0xD6336C))],
                             format: { Format.rate($0) })
                    BigChart(title: "Processeur graphique", value: sample.gpu.map { Format.percent($0.utilization) } ?? "—",
                             detail: sample.gpu.map { _ in "utilisation du GPU" } ?? "non disponible",
                             series: [("GPU", monitor.gpuHistory, Color(hex: 0xB42318))], format: { Format.percent($0) }, maximum: 100)
                    cores(sample)
                }
                memoryBreakdown(sample)
                energy(sample, monitor: monitor)
            } else {
                ScanningCard(label: "Première mesure…")
            }
        }
        .onAppear { monitor.attach() }
        .onDisappear { monitor.detach() }
    }

    private func cores(_ sample: SystemSample) -> some View {
        let machine = model.performance.machine
        return VStack(alignment: .leading, spacing: 8) {
            Text("Cœurs").font(.system(size: 15, weight: .semibold))
            Text("\(machine.efficiencyCores) efficacité · \(machine.performanceCores) performance").font(.system(size: 12)).foregroundStyle(Theme.muted)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(sample.cores.enumerated()), id: \.offset) { index, load in
                    VStack(spacing: 4) {
                        GeometryReader { geometry in
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(index < machine.efficiencyCores ? Color(hex: 0x1E8A45) : Theme.accent)
                                    .frame(height: max(2, geometry.size.height * load / 100))
                            }
                        }
                        Text("\(Int(load))").font(.system(size: 9)).monospacedDigit().foregroundStyle(Theme.muted)
                    }
                }
            }
            .frame(height: 150)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(radius: 18)
    }

    private func memoryBreakdown(_ sample: SystemSample) -> some View {
        let memory = sample.memory
        let free = max(0, memory.total - memory.app - memory.wired - memory.compressed - memory.cached)
        let parts: [(String, Int64, Color)] = [
            ("Apps", memory.app, Color(hex: 0x6E4BD8)), ("Réservée (système)", memory.wired, Color(hex: 0xB42318)),
            ("Compressée", memory.compressed, Color(hex: 0xE8890C)), ("Fichiers en cache", memory.cached, Color(hex: 0x00879E)),
            ("Libre", free, Theme.hairline),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            Text("Répartition de la mémoire").font(.system(size: 15, weight: .semibold))
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { part in
                        Rectangle().fill(part.2).frame(width: max(2, geometry.size.width * Double(part.1) / Double(max(memory.total, 1))))
                    }
                }
            }
            .frame(height: 22)
            .clipShape(.rect(cornerRadius: 6))
            HStack(spacing: 16) {
                ForEach(parts, id: \.0) { part in
                    HStack(spacing: 5) {
                        Circle().fill(part.2).frame(width: 9, height: 9)
                        Text(part.0).font(.system(size: 12))
                        Text(Format.bytes(part.1)).font(.system(size: 12, weight: .semibold))
                    }
                }
            }
        }
        .padding(16)
        .cardBackground(radius: 18)
    }

    private func energy(_ sample: SystemSample, monitor: PerformanceMonitor) -> some View {
        let top = monitor.processes.sorted { $0.cpu + $0.wakeups / 50 > $1.cpu + $1.wakeups / 50 }.prefix(6)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Énergie").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text([sample.power.batteryLevel.map { "Batterie \($0) %" }, sample.power.onBattery ? "sur batterie" : "sur secteur",
                      sample.power.charging ? "en charge" : nil, "température \(sample.power.thermalLabel)"]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            ForEach(Array(top)) { process in
                Button { model.processDetail = ProcessDetailRequest(pid: process.pid) } label: {
                    HStack {
                        ProcessIcon(name: process.displayName, bundle: process.appBundle).frame(width: 18, height: 18)
                        Text(process.displayName).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        Text(Format.percent(process.cpu)).monospacedDigit().frame(width: 70, alignment: .trailing)
                        Text("\(Int(process.wakeups)) réveils/s").monospacedDigit().foregroundStyle(Theme.muted).frame(width: 110, alignment: .trailing)
                    }
                    .font(.system(size: 12))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .cardBackground(radius: 18)
    }
}

/// Grand graphique avec axes, une ou plusieurs courbes.
private struct BigChart: View {
    let title: String
    let value: String
    let detail: String
    let series: [(String, [Double], Color)]
    let format: (Double) -> String
    var maximum: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(value).font(.system(size: 20, weight: .bold)).monospacedDigit()
            }
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            Chart {
                ForEach(series, id: \.0) { serie in
                    ForEach(Array(serie.1.enumerated()), id: \.offset) { point in
                        LineMark(x: .value("Secondes", point.offset - serie.1.count), y: .value(serie.0, point.element),
                                 series: .value("Série", serie.0))
                            .foregroundStyle(serie.2)
                            .interpolationMethod(.monotone)
                        if series.count == 1 {
                            AreaMark(x: .value("Secondes", point.offset - serie.1.count), y: .value(serie.0, point.element))
                                .foregroundStyle(serie.2.opacity(0.15))
                                .interpolationMethod(.monotone)
                        }
                    }
                }
            }
            .chartYScale(domain: 0...(maximum ?? max(1, series.flatMap(\.1).max() ?? 1) * 1.1))
            .chartXAxis {
                AxisMarks(values: .stride(by: 60)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Int.self) { Text(v == 0 ? "maintenant" : "\(v / 60) min").font(.system(size: 9)) } }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text(format(v)).font(.system(size: 9)) } }
                }
            }
            .frame(height: 170)
            if series.count > 1 {
                HStack(spacing: 12) {
                    ForEach(series, id: \.0) { serie in
                        HStack(spacing: 4) {
                            Circle().fill(serie.2).frame(width: 8, height: 8)
                            Text(serie.0).font(.system(size: 11))
                        }
                    }
                }
            }
        }
        .padding(16)
        .cardBackground(radius: 18)
    }
}
