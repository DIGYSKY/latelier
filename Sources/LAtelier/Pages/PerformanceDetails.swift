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
        Task {
            http[port] = await Self.speaksHTTP(port)
        }
    }

    /// Envoie « HEAD / HTTP/1.0 » sur le port local et exige une réponse qui commence par « HTTP/ ».
    /// (Une base de données ou un autre protocole répond autrement, ou pas du tout.)
    static func speaksHTTP(_ port: Int) async -> Bool {
        let task = URLSession.shared.streamTask(withHostName: "localhost", port: port)
        task.resume()
        defer { task.cancel() }
        do {
            try await task.write(Data("HEAD / HTTP/1.0\r\nHost: localhost\r\n\r\n".utf8), timeout: 1.5)
            let (data, _) = try await task.readData(ofMinLength: 5, maxLength: 64, timeout: 1.5)
            return String(decoding: data ?? Data(), as: UTF8.self).hasPrefix("HTTP/")
        } catch {
            return false
        }
    }

    static func address(_ port: Int, http: Bool) -> String { http ? "http://localhost:\(port)" : "localhost:\(port)" }
}

/// Boutons d'un port en écoute : ouvrir dans le navigateur (si HTTP), copier l'adresse.
struct PortActions: View {
    let port: ListeningPort
    /// Icônes seules (cartes étroites), pour laisser la place au nom du processus.
    var compact = false
    private var probe: PortProbe { .shared }

    var body: some View {
        let http = probe.http[port.port] == true
        HStack(spacing: compact ? 4 : 6) {
            if http {
                Button {
                    if let url = URL(string: PortProbe.address(port.port, http: true)) { NSWorkspace.shared.open(url) }
                } label: {
                    if compact { icon("safari") } else { Label("Ouvrir", systemImage: "safari").fixedSize() }
                }
                .buttonStyle(compactStyle)
                .help(String(localized: "Ouvrir http://localhost:\(String(port.port)) dans le navigateur"))
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(PortProbe.address(port.port, http: http), forType: .string)
            } label: { compact ? AnyView(icon("doc.on.doc")) : AnyView(Image(systemName: "doc.on.doc")) }
                .buttonStyle(compactStyle)
                .help(String(localized: "Copier \(PortProbe.address(port.port, http: http))"))
                .accessibilityLabel(String(localized: "Copier l’adresse"))
        }
        .onAppear { probe.check(port.port) }
    }

    /// Petite icône ronde (cartes étroites).
    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .frame(width: 26, height: 26)
            .background(Theme.raised, in: .circle)
            .overlay(Circle().strokeBorder(Theme.hairline))
            .contentShape(.circle)
    }

    private var compactStyle: AnyButtonStyle { compact ? AnyButtonStyle(BareButtonStyle()) : AnyButtonStyle(PillButtonStyle(kind: .small)) }
}

/// Bouton sans décor (l'étiquette dessine tout), légèrement estompé quand on appuie.
struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Style de bouton choisi à l'exécution.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

extension View {
    /// Menu contextuel d'un port : ouvrir, copier l'adresse, copier le PID.
    func portContextMenu(_ port: ListeningPort) -> some View {
        contextMenu {
            let http = PortProbe.shared.http[port.port] == true
            if http, let url = URL(string: PortProbe.address(port.port, http: true)) {
                Button(String(localized: "Ouvrir \(url.absoluteString)")) { NSWorkspace.shared.open(url) }
            }
            Button(String(localized: "Copier \(PortProbe.address(port.port, http: http))")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(PortProbe.address(port.port, http: http), forType: .string)
            }
            Button(String(localized: "Copier le PID (\(String(port.pid)))")) {
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
                ProgressView(String(localized: "Lecture du processus \(String(pid))…")).padding(40)
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
                Text(String(localized: "PID \(String(process.pid)) · \(process.userLabel) · \(process.energy == .high ? String(localized: "impact énergétique élevé") : String(localized: "impact énergétique \(energyLabel(process.energy))"))"))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if process.canQuit {
                Button(String(localized: "Quitter")) {
                    dismiss()
                    model.quit([process.target], label: process.displayName, force: false)
                }
                .buttonStyle(PillButtonStyle(kind: .small))
                Button(String(localized: "Forcer")) {
                    dismiss()
                    model.quit([process.target], label: process.displayName, force: true)
                }
                .buttonStyle(PillButtonStyle(kind: .small))
            }
            Button(String(localized: "Fermer")) { dismiss() }
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
        case .high: String(localized: "élevé")
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
        return section(String(localized: "Performances (2 dernières minutes)")) {
            HStack(spacing: 10) {
                StatTile(label: String(localized: "Processeur"), value: Format.percent(process.cpu))
                StatTile(label: String(localized: "Mémoire"), value: Format.ram(process.memory))
                StatTile(label: "Threads", value: process.threads.map(String.init) ?? "—")
                StatTile(label: String(localized: "Réveils / s"), value: Format.decimal(process.wakeups, decimals: 0))
            }
            HStack(spacing: 14) {
                chart(String(localized: "Processeur (%)"), values: history.map(\.cpu), color: Theme.accent) { Format.percent($0) }
                chart(String(localized: "Mémoire"), values: history.map { Double($0.memory) }, color: Color(hex: 0x6E4BD8)) { Format.ram(Int64($0)) }
            }
            .frame(height: 150)
            HStack(spacing: 10) {
                StatTile(label: String(localized: "Lu sur le disque"), value: Format.bytes(Int64(process.diskRead)))
                StatTile(label: String(localized: "Écrit sur le disque"), value: Format.bytes(Int64(process.diskWritten)))
                if let rate = monitor.traffic[pid] {
                    StatTile(label: String(localized: "Réseau ↓ / ↑"), value: "\(Format.rate(rate.down)) / \(Format.rate(rate.up))")
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
        section(String(localized: "Identité")) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                row(String(localized: "Exécutable"), process.path ?? String(localized: "inconnu (processus d’un autre compte)"), mono: true)
                if let arguments, arguments.count > 1 {
                    row("Arguments", RecorderDetector.displayCommand(arguments), mono: true)
                }
                if let cwd = process.cwd { row(String(localized: "Dossier de travail"), cwd, mono: true) }
                if let project = process.cwd.flatMap({ ProjectMatcher.project(for: $0, in: model.knownProjects) }) {
                    row(String(localized: "Projet"), model.projectName(project), mono: false)
                }
                let start = Date(timeIntervalSince1970: TimeInterval(process.started))
                row(String(localized: "Démarré"), start.formatted(date: .abbreviated, time: .standard) + String(localized: " · depuis ") + Self.uptime(Date().timeIntervalSince(start)), mono: false)
                row(String(localized: "Utilisateur"), process.userLabel, mono: false)
                if let signer {
                    row(String(localized: "Signature"), signer.apple ? "Apple" : (signer.name ?? String(localized: "signé")) + (signer.teamID.map { " (\($0))" } ?? ""), mono: false)
                } else if process.path != nil {
                    row(String(localized: "Signature"), String(localized: "non signé ou illisible"), mono: false)
                }
            }
            HStack(spacing: 8) {
                if let path = process.path {
                    Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        .buttonStyle(PillButtonStyle(kind: .small))
                }
                Button(String(localized: "Copier la commande")) {
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
        if s < 86_400 { return String(localized: "\(s / 3600) h \(s % 3600 / 60) min") }
        return String(localized: "\(s / 86_400) j \(s % 86_400 / 3600) h")
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
        return section(String(localized: "Arborescence")) {
            HStack {
                Text("Parent").font(.system(size: 12)).foregroundStyle(Theme.muted)
                if let parent {
                    Button(String(localized: "\(parent.displayName) (PID \(String(parent.pid)))")) { model.processDetail = ProcessDetailRequest(pid: parent.pid) }
                        .buttonStyle(.link)
                } else {
                    Text("PID \(process.ppid)").font(.system(size: 13))
                }
            }
            if kids.isEmpty {
                Text("Aucun processus enfant.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            } else {
                Text((kids.count > 1 ? String(localized: "\(kids.count) processus enfants · \(Format.percent(kids.reduce(0) { $0 + $1.cpu })) CPU · \(Format.ram(kids.reduce(0) { $0 + $1.memory }))") : String(localized: "\(kids.count) processus enfant · \(Format.percent(kids.reduce(0) { $0 + $1.cpu })) CPU · \(Format.ram(kids.reduce(0) { $0 + $1.memory }))")))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                ForEach(kids.prefix(12)) { child in
                    HStack {
                        Button(child.displayName) { model.processDetail = ProcessDetailRequest(pid: child.pid) }.buttonStyle(.link)
                        Text("PID \(child.pid)").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        Spacer()
                        Text(Format.percent(child.cpu)).monospacedDigit().frame(width: 60, alignment: .trailing)
                        Text(Format.ram(child.memory)).monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                    .font(.system(size: 12))
                }
            }
        }
    }

    private func network(_ process: RunningProcess, monitor: PerformanceMonitor) -> some View {
        let ports = monitor.ports.filter { $0.pid == pid }
        let connections = monitor.connections[pid]
        return section(String(localized: "Réseau")) {
            if ports.isEmpty && connections == nil {
                Text("Aucun port ouvert ni connexion établie.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            ForEach(ports) { port in
                HStack {
                    Text(":\(String(port.port))").font(.system(size: 13, weight: .bold).monospaced())
                    Text(port.displayAddress).font(.system(size: 12).monospaced()).foregroundStyle(Theme.muted)
                    if port.exposed { Tag(text: String(localized: "Exposé au réseau local"), foreground: Tag.orange.0, background: Tag.orange.1) }
                    Spacer()
                    PortActions(port: port)
                }
                .portContextMenu(port)
            }
            if let connections {
                Text((connections.count > 1 ? String(localized: "\(connections.count) connexions établies") : String(localized: "\(connections.count) connexion établie"))
                     + (connections.hosts.isEmpty ? "" : " · " + connections.hosts.prefix(6).joined(separator: ", ")))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).textSelection(.enabled)
            }
        }
    }
}

// MARK: - Moniteur : les performances en grand

struct MonitorPage: View {
    /// 0, 4, 8, 12, 16 Go pour 16 Go de RAM : multiples ronds de Gio, quatre ou cinq graduations.
    static func memoryTicks(_ total: Int64) -> [Double] {
        let gib = Double(1 << 30)
        let totalGiB = Double(total) / gib
        let step = [1.0, 2, 4, 8, 16, 32, 64].first { totalGiB / $0 <= 5 } ?? 128
        return stride(from: 0, through: totalGiB + 0.01, by: step).map { $0 * gib }
    }

    @Environment(AppModel.self) private var model

    var body: some View {
        let monitor = model.performance
        PageScaffold(page: .moniteur, subtitle: String(localized: "\(monitor.machine.chip) · 5 dernières minutes, une mesure par seconde")) {
            Button(monitor.paused ? String(localized: "Reprendre") : "Pause", systemImage: monitor.paused ? "play.fill" : "pause.fill") { monitor.paused.toggle() }
                .buttonStyle(.secondary)
        } content: {
            if let sample = monitor.latest {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    BigChart(title: String(localized: "Processeur"), value: Format.percent(sample.cpu),
                             detail: String(localized: "Performance \(Format.percent(sample.performanceLoad)) · Efficacité \(Format.percent(sample.efficiencyLoad))"),
                             series: [("Total", monitor.cpuHistory, Theme.accent)], format: { Format.percent($0) }, maximum: 100)
                    BigChart(title: String(localized: "Mémoire"), value: Format.ram(sample.memory.used),
                             detail: String(localized: "sur \(Format.ram(sample.memory.total)) · pression \(sample.memory.pressure.label) · swap \(Format.ram(sample.memory.swapUsed))"),
                             series: [(String(localized: "Utilisée"), monitor.memoryHistory, Color(hex: 0x6E4BD8))], format: { Format.ram(Int64($0)) },
                             maximum: Double(sample.memory.total), ticks: Self.memoryTicks(sample.memory.total))
                    BigChart(title: String(localized: "Disque"), value: "\(Format.rate(sample.diskRead)) ↓  \(Format.rate(sample.diskWrite)) ↑",
                             detail: sample.diskFree.map { "\(Format.bytes($0)) libres" } ?? String(localized: "lecture et écriture"),
                             series: [(String(localized: "Lecture"), monitor.diskReadHistory, Color(hex: 0x00879E)), (String(localized: "Écriture"), monitor.diskWriteHistory, Color(hex: 0xE8890C))],
                             format: { Format.rate($0) })
                    BigChart(title: String(localized: "Réseau"), value: "\(Format.rate(sample.networkIn)) ↓  \(Format.rate(sample.networkOut)) ↑",
                             detail: sample.network.primaryName ?? String(localized: "réception et envoi"),
                             series: [(String(localized: "Reçu"), monitor.netInHistory, Color(hex: 0x1E8A45)), (String(localized: "Envoyé"), monitor.netOutHistory, Color(hex: 0xD6336C))],
                             format: { Format.rate($0) })
                    BigChart(title: String(localized: "Processeur graphique"), value: sample.gpu.map { Format.percent($0.utilization) } ?? "—",
                             detail: sample.gpu.map { _ in String(localized: "utilisation du GPU") } ?? String(localized: "non disponible"),
                             series: [("GPU", monitor.gpuHistory, Color(hex: 0xB42318))], format: { Format.percent($0) }, maximum: 100)
                    cores(sample)
                }
                memoryBreakdown(sample)
                energy(sample, monitor: monitor)
            } else {
                ScanningCard(label: String(localized: "Première mesure…"))
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
            ("Apps", memory.app, Color(hex: 0x6E4BD8)), (String(localized: "Réservée (système)"), memory.wired, Color(hex: 0xB42318)),
            (String(localized: "Compressée"), memory.compressed, Color(hex: 0xE8890C)), (String(localized: "Fichiers en cache"), memory.cached, Color(hex: 0x00879E)),
            (String(localized: "Libre"), free, Theme.hairline),
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
                        Text(Format.ram(part.1)).font(.system(size: 12, weight: .semibold))
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
                Text([sample.power.batteryLevel.map { String(localized: "Batterie \($0) %") }, sample.power.onBattery ? String(localized: "sur batterie") : String(localized: "sur secteur"),
                      sample.power.charging ? String(localized: "en charge") : nil, String(localized: "température \(sample.power.thermalLabel)")]
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
                        Text(String(localized: "\(Int(process.wakeups)) réveils/s")).monospacedDigit().foregroundStyle(Theme.muted).frame(width: 110, alignment: .trailing)
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
struct BigChart: View {
    let title: String
    let value: String
    let detail: String
    let series: [(String, [Double], Color)]
    let format: (Double) -> String
    var maximum: Double?
    /// Graduations imposées (mémoire : multiples ronds de Gio), sinon automatiques.
    var ticks: [Double]?
    /// Points affichés sur la largeur, et durée entre deux points (local : 1 s ; serveur : 2 s).
    var window = 300
    var secondsPerPoint: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(value).font(.system(size: 20, weight: .bold)).monospacedDigit()
            }
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            LightChart(series: series, maximum: maximum, ticks: ticks, format: format,
                       window: window, secondsPerPoint: secondsPerPoint)
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

/// Graphique dessiné directement (Canvas) : quelques centaines de points redessinés chaque seconde
/// coûtent bien moins qu'avec Swift Charts, qui recrée une vue par point.
struct LightChart: View {
    let series: [(String, [Double], Color)]
    var maximum: Double?
    var ticks: [Double]?
    let format: (Double) -> String
    var window = 300
    var secondsPerPoint: Double = 1

    private let left: CGFloat = 58
    private let bottom: CGFloat = 16

    var body: some View {
        let (top, marks) = scale()
        Canvas { context, size in
            let plot = CGRect(x: left, y: 6, width: max(1, size.width - left - 4), height: max(1, size.height - bottom - 6))
            func y(_ value: Double) -> CGFloat { plot.maxY - CGFloat(min(max(value, 0), top) / top) * plot.height }
            let grid = GraphicsContext.Shading.color(Color.secondary.opacity(0.18))

            // Graduations horizontales et leurs valeurs.
            for mark in marks {
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y(mark)))
                line.addLine(to: CGPoint(x: plot.maxX, y: y(mark)))
                context.stroke(line, with: grid, lineWidth: 0.5)
                context.draw(Text(format(mark)).font(.system(size: 9)).foregroundStyle(.secondary),
                             at: CGPoint(x: plot.minX - 6, y: y(mark)), anchor: .trailing)
            }
            // Repères de temps toutes les minutes, depuis la droite (maintenant).
            let step = plot.width / CGFloat(max(1, window - 1))
            let perMinute = Int((60 / secondsPerPoint).rounded())
            if perMinute > 0 {
                var index = perMinute
                while index < window {
                    let x = plot.maxX - CGFloat(index) * step
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: plot.minY))
                    line.addLine(to: CGPoint(x: x, y: plot.maxY))
                    context.stroke(line, with: grid, style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    context.draw(Text("-\(index / perMinute) min").font(.system(size: 9)).foregroundStyle(.secondary),
                                 at: CGPoint(x: x, y: plot.maxY + 3), anchor: .top)
                    index += perMinute
                }
            }
            // Courbes, alignées à droite (le dernier point est « maintenant »).
            for serie in series {
                let values = Array(serie.1.suffix(window))
                guard values.count > 1 else { continue }
                let points = values.enumerated().map { offset, value in
                    CGPoint(x: plot.maxX - CGFloat(values.count - 1 - offset) * step, y: y(value))
                }
                let curve = Self.smooth(points)
                if series.count == 1 {
                    var area = curve
                    area.addLine(to: CGPoint(x: points.last!.x, y: plot.maxY))
                    area.addLine(to: CGPoint(x: points.first!.x, y: plot.maxY))
                    area.closeSubpath()
                    context.fill(area, with: .color(serie.2.opacity(0.15)))
                }
                context.stroke(curve, with: .color(serie.2), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: 170)
        .accessibilityElement()
        .accessibilityLabel(series.map { "\($0.0) : \($0.1.last.map(format) ?? "—")" }.joined(separator: ", "))
    }

    /// Haut de l'échelle et graduations : imposés, ou « ronds » (1, 2, 2,5, 5 × 10ⁿ).
    private func scale() -> (Double, [Double]) {
        let peak = series.flatMap { $0.1.suffix(window) }.max() ?? 0
        if let ticks, let last = ticks.last {
            return (max(maximum ?? last, last, 1e-9), ticks)
        }
        let target = maximum ?? max(peak * 1.1, 1)
        let rough = target / 4
        let magnitude = pow(10, floor(log10(rough)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= rough } ?? rough
        let top = maximum ?? (target / step).rounded(.up) * step
        let marks = stride(from: 0, through: top + step * 0.01, by: step).map { $0 }
        return (top, marks)
    }

    /// Courbe monotone (Fritsch-Carlson) : lisse, sans dépasser les valeurs mesurées.
    static func smooth(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        let n = points.count
        var slopes = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = points[i + 1].x - points[i].x
            slopes[i] = dx == 0 ? 0 : (points[i + 1].y - points[i].y) / dx
        }
        var tangents = [CGFloat](repeating: 0, count: n)
        tangents[0] = slopes[0]
        tangents[n - 1] = slopes[n - 2]
        for i in 1..<(n - 1) {
            tangents[i] = slopes[i - 1] * slopes[i] <= 0 ? 0 : (slopes[i - 1] + slopes[i]) / 2
        }
        for i in 0..<(n - 1) {
            let dx = (points[i + 1].x - points[i].x) / 3
            path.addCurve(to: points[i + 1],
                          control1: CGPoint(x: points[i].x + dx, y: points[i].y + tangents[i] * dx),
                          control2: CGPoint(x: points[i + 1].x - dx, y: points[i + 1].y - tangents[i + 1] * dx))
        }
        return path
    }
}
