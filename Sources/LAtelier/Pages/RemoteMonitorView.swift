import AppKit
import LAtelierCore
import SwiftUI

/// Onglet Moniteur d'un serveur : ressources en direct, partitions, processus, services, Docker, ports.
/// Les actions passent par l'aperçu ; celles qui demandent sudo s'ouvrent dans le terminal.
struct RemoteMonitorView: View {
    @Environment(AppModel.self) private var model
    let monitor: RemoteMonitorStore
    let host: SSHHost
    @ViewState private var query = ""
    @ViewState private var sortByMemory = false
    @ViewState private var hideKernel = true
    @ViewState private var showAllServices = false
    @ViewState private var processLimit = 25
    @ViewState private var terminalRequest: TerminalRequest?

    struct TerminalRequest: Identifiable {
        let id = UUID()
        let command: String
        let reason: String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Tracked { header }
                if let error = monitor.error, !monitor.hasSample {
                    errorCard(error)
                } else if !monitor.hasSample {
                    Card {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(monitor.paused ? String(localized: "En pause.") : String(localized: "Connexion à \(host.alias) et première mesure…"))
                                .font(.system(size: 13)).foregroundStyle(Theme.muted)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120)
                    }
                } else {
                    if let error = monitor.error { lostBanner(error) }
                    // Chaque section suit seulement ses données : une mesure ne redessine pas toute la page.
                    // Captures : LATELIER_SSH_LOWER=1 montre directement le bas de l'onglet.
                    if ProcessInfo.processInfo.environment["LATELIER_SSH_LOWER"] == nil { Tracked { charts } }
                    Tracked { disksCard }
                    Tracked { processesCard }
                    HStack(alignment: .top, spacing: 14) {
                        Tracked { servicesCard }
                        VStack(spacing: 14) {
                            Tracked { dockerCard }
                            Tracked { portsCard }
                        }
                    }
                }
            }
            .padding(.leading, 22).padding(.trailing, 30).padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .onAppear { monitor.attach() }
        .onDisappear { monitor.detach() }
        .alert(String(localized: "Droits administrateur nécessaires"), isPresented: Binding(get: { terminalRequest != nil }, set: { if !$0 { terminalRequest = nil } })) {
            Button(String(localized: "Annuler"), role: .cancel) { terminalRequest = nil }
            Button(String(localized: "Ouvrir dans le terminal")) {
                if let request = terminalRequest, let error = model.ssh.openTerminal(host.alias, remote: request.command) { model.launchError = error }
                terminalRequest = nil
            }
        } message: {
            if let request = terminalRequest {
                Text("\(request.reason)\n\n\(request.command)")
            }
        }
    }

    // MARK: En-tête

    private var header: some View {
        HStack(spacing: 10) {
            if let info = monitor.info {
                chip("server.rack", info.os)
                chip("cpu", String(localized: "\(monitor.latest?.cores.count ?? 0) cœurs"))
                chip("power", String(localized: "allumé depuis \(Self.duration(info.uptime))"))
                chip("person.2", "\(info.users) session\(info.users > 1 ? "s" : "")")
                chip(info.isRoot ? "lock.open" : "person", info.isRoot ? "root" : info.login + (info.canSudo ? " · sudo" : ""))
                    .help(info.canSudo ? String(localized: "Les actions administrateur passent par l’aperçu (sudo sans mot de passe ou root).")
                          : String(localized: "Les actions administrateur s’ouvrent dans le terminal, où sudo vous demandera votre mot de passe."))
            }
            Spacer()
            if monitor.running, monitor.latest != nil {
                HStack(spacing: 5) {
                    Circle().fill(Theme.green).frame(width: 7, height: 7)
                    Text("en direct · toutes les 2 s").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            Button(monitor.paused ? String(localized: "Reprendre") : "Pause", systemImage: monitor.paused ? "play.fill" : "pause.fill") { monitor.togglePause() }
                .buttonStyle(.small).fixedSize()
        }
    }

    private func chip(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.cardFill, in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.cardBorder))
    }

    private func errorCard(_ error: (title: String, advice: String)) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label(error.title, systemImage: "bolt.horizontal.circle").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.red)
                Text(error.advice).font(.system(size: 13)).foregroundStyle(Theme.muted)
                HStack(spacing: 8) {
                    Button("Réessayer", systemImage: "arrow.clockwise") { monitor.retry() }.buttonStyle(PillButtonStyle(kind: .smallFilled))
                    TerminalButton(alias: host.alias, filled: false)
                }
            }
            .padding(4)
        }
    }

    private func lostBanner(_ error: (title: String, advice: String)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
            Text("Connexion perdue : \(error.title). Les dernières valeurs restent affichées.").font(.system(size: 13))
            Spacer()
            Button(String(localized: "Reconnecter")) { monitor.retry() }.buttonStyle(PillButtonStyle(kind: .smallFilled))
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Theme.orange.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
    }

    // MARK: Graphiques

    private var charts: some View {
        let sample = monitor.latest!
        return VStack(spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                BigChart(
                    title: String(localized: "Processeur"), value: Format.percent(sample.cpu),
                    detail: String(localized: "charge \(sample.load.map { Format.decimal($0, decimals: 2) }.joined(separator: " · ")) · attente disque \(Format.percent(sample.iowait))"),
                    series: [("CPU", monitor.cpuHistory, Theme.accent)], format: { Format.percent($0) }, maximum: 100,
                    window: RemoteMonitorStore.historyLength, secondsPerPoint: 2
                )
                BigChart(
                    title: String(localized: "Mémoire"), value: Format.ram(sample.memoryUsed),
                    detail: String(localized: "sur \(Format.ram(sample.memoryTotal)) · cache \(Format.ram(sample.memoryCached))")
                        + (sample.swapTotal > 0 ? String(localized: " · swap \(Format.ram(sample.swapUsed)) / \(Format.ram(sample.swapTotal))") : String(localized: " · pas de swap")),
                    series: [(String(localized: "Utilisée"), monitor.memoryHistory, Color(hex: 0x6E4BD8))], format: { Format.ram(Int64($0)) },
                    maximum: Double(sample.memoryTotal), ticks: MonitorPage.memoryTicks(sample.memoryTotal),
                    window: RemoteMonitorStore.historyLength, secondsPerPoint: 2
                )
                BigChart(
                    title: String(localized: "Réseau"), value: "\(Format.rate(sample.networkIn)) ↓  \(Format.rate(sample.networkOut)) ↑",
                    detail: String(localized: "toutes les interfaces, hors Docker et boucle locale"),
                    series: [(String(localized: "Reçu"), monitor.networkInHistory, Color(hex: 0x1E8A45)), (String(localized: "Envoyé"), monitor.networkOutHistory, Color(hex: 0xD6336C))],
                    format: { Format.rate($0) }, window: RemoteMonitorStore.historyLength, secondsPerPoint: 2
                )
                BigChart(
                    title: String(localized: "Disque"), value: "\(Format.rate(sample.diskRead)) ↓  \(Format.rate(sample.diskWrite)) ↑",
                    detail: String(localized: "lecture et écriture, tous les disques"),
                    series: [(String(localized: "Lecture"), monitor.diskReadHistory, Color(hex: 0x00879E)), (String(localized: "Écriture"), monitor.diskWriteHistory, Color(hex: 0xE8590C))],
                    format: { Format.rate($0) }, window: RemoteMonitorStore.historyLength, secondsPerPoint: 2
                )
            }
            if sample.cores.count > 1 { coresCard(sample.cores) }
        }
    }

    private func coresCard(_ cores: [Double]) -> some View {
        Card(title: String(localized: "Cœurs"), trailing: String(localized: "\(cores.count) cœurs · moyenne \(Format.percent(cores.reduce(0, +) / Double(cores.count)))")) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(cores.enumerated()), id: \.offset) { index, value in
                    VStack(spacing: 3) {
                        GeometryReader { geometry in
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(value > 85 ? Theme.red : value > 50 ? Theme.orange : Theme.accent)
                                    .frame(height: max(2, geometry.size.height * value / 100))
                            }
                        }
                        .frame(height: 50)
                        .background(Theme.hairline.opacity(0.5), in: .rect(cornerRadius: 3))
                        Text("\(index)").font(.system(size: 9)).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }

    // MARK: Partitions

    private var disksCard: some View {
        Card(title: "Partitions", trailing: monitor.disks.isEmpty ? nil : String(localized: "\(Format.bytes(monitor.disks.reduce(0) { $0 + $1.available })) libres au total")) {
            if monitor.disks.isEmpty {
                Text("Mesure des partitions…").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            ForEach(monitor.disks) { disk in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(disk.mount).font(.system(size: 13, weight: .semibold).monospaced()).lineLimit(1)
                        Text("\(disk.device) · \(disk.type)").font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    .frame(width: 220, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.hairline)
                            Capsule().fill(color(disk.fraction)).frame(width: max(4, geometry.size.width * disk.fraction))
                        }
                    }
                    .frame(height: 8)
                    Text(Format.percent(disk.fraction * 100)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(disk.fraction > 0.9 ? Theme.red : .primary).frame(width: 44, alignment: .trailing)
                    Text("\(Format.bytes(disk.available)) libres sur \(Format.bytes(disk.size))").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .frame(width: 190, alignment: .trailing)
                }
            }
        }
    }

    private func color(_ fraction: Double) -> Color {
        fraction > 0.9 ? Theme.red : fraction > 0.75 ? Theme.orange : Theme.green
    }

    // MARK: Processus

    private var visibleProcesses: [RemoteProcess] {
        let q = query.lowercased()
        var list = monitor.processes.filter { process in
            (!hideKernel || !process.isKernelThread) && (q.isEmpty || process.command.lowercased().contains(q) || process.user.lowercased().contains(q) || String(process.pid) == q)
        }
        if sortByMemory { list.sort { $0.resident > $1.resident } }
        return Array(list.prefix(processLimit))
    }

    private var processesCard: some View {
        Card {
            HStack(spacing: 10) {
                Text("Processus").font(.system(size: 15, weight: .semibold))
                Text("les plus actifs et les plus gros").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                SearchField(prompt: String(localized: "Nom, utilisateur ou PID"), text: $query).frame(width: 240)
                GlassSegments(selection: $sortByMemory, items: [(false, "CPU"), (true, String(localized: "Mémoire"))], compact: true).fixedSize()
                Toggle(String(localized: "Threads du noyau"), isOn: Binding(get: { !hideKernel }, set: { hideKernel = !$0 }))
                    .toggleStyle(.checkbox).font(.system(size: 12))
            }
            HStack(spacing: 10) {
                Text("PID").frame(width: 70, alignment: .leading)
                Text(String(localized: "Utilisateur")).frame(width: 110, alignment: .leading)
                Text("CPU").frame(width: 60, alignment: .trailing)
                Text(String(localized: "Mémoire")).frame(width: 80, alignment: .trailing)
                Text(String(localized: "Depuis")).frame(width: 80, alignment: .trailing)
                Text(String(localized: "Commande")).frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 28)
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            VStack(spacing: 1) {
                ForEach(visibleProcesses) { process in
                    processRow(process)
                }
            }
            if monitor.processes.count > processLimit {
                Button(processLimit > 25 ? String(localized: "Afficher moins") : String(localized: "Afficher plus de processus")) { processLimit = processLimit > 25 ? 25 : 80 }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.link)
            }
        }
    }

    private func processRow(_ process: RemoteProcess) -> some View {
        HoverRow { hovering in
        HStack(spacing: 10) {
            Text(String(process.pid)).font(.system(size: 12).monospaced()).frame(width: 70, alignment: .leading)
            Text(process.user).lineLimit(1).frame(width: 110, alignment: .leading)
                .foregroundStyle(process.user == monitor.info?.login ? .primary : Theme.muted)
            Text(Format.percent(process.cpu, decimals: process.cpu < 10 ? 1 : 0)).monospacedDigit().frame(width: 60, alignment: .trailing)
                .foregroundStyle(process.cpu > 80 ? Theme.red : process.cpu > 30 ? Theme.orange : .primary)
                .fontWeight(process.cpu > 30 ? .semibold : .regular)
            Text(Format.ram(process.resident)).monospacedDigit().frame(width: 80, alignment: .trailing)
            Text(Self.duration(TimeInterval(process.elapsed))).foregroundStyle(Theme.muted).frame(width: 80, alignment: .trailing)
            Text(process.command).font(.system(size: 12).monospaced()).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            HoverMenu(hovering: hovering) { processActions(process) }
        }
        .font(.system(size: 12))
        .padding(.vertical, 4).padding(.horizontal, 6)
        .contentShape(.rect)
        .contextMenu { processActions(process) }
        }
    }

    @ViewBuilder
    private func processActions(_ process: RemoteProcess) -> some View {
        Button("Arrêter…", systemImage: "stop.circle") { run(monitor.stopProcess(process, force: false)) }
            .disabled(process.isKernelThread || process.pid == 1)
        Button("Forcer l’arrêt…", systemImage: "xmark.octagon") { run(monitor.stopProcess(process, force: true)) }
            .disabled(process.isKernelThread || process.pid == 1)
        Divider()
        Button("Copier la commande", systemImage: "doc.on.doc") { copy(process.command) }
        Button("Copier le PID", systemImage: "number") { copy(String(process.pid)) }
    }

    // MARK: Services

    private var servicesCard: some View {
        let failed = monitor.services.filter(\.failed)
        let running = monitor.services.filter { !$0.failed }
        let shown = showAllServices ? running : Array(running.prefix(10))
        return Card(title: String(localized: "Services systemd"), trailing: monitor.servicesAvailability == .absent ? nil
                    : "\(running.count) actif\(running.count > 1 ? "s" : "")" + (failed.isEmpty ? "" : String(localized: " · \(failed.count) en échec"))) {
            switch monitor.servicesAvailability {
            case .absent:
                Text("systemd n’est pas utilisé sur ce serveur.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            case nil:
                Text("Lecture des services…").font(.system(size: 12)).foregroundStyle(Theme.muted)
            default:
                ForEach(failed + shown) { service in serviceRow(service) }
                if running.count > 10 {
                    Button(showAllServices ? String(localized: "Afficher moins") : String(localized: "Afficher les \(running.count) services")) { showAllServices.toggle() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.link)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func serviceRow(_ service: RemoteService) -> some View {
        HoverRow { hovering in
        HStack(spacing: 8) {
            Circle().fill(service.failed ? Theme.red : Theme.green).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(service.description).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            if service.failed { Tag(text: String(localized: "en échec"), foreground: Tag.red.0, background: Tag.red.1) }
            HoverMenu(hovering: hovering) {
                ForEach(RemoteActions.ServiceAction.allCases, id: \.self) { action in
                    if action == .start ? !service.running : (action == .stop ? service.running : true) {
                        Button("\(action.label)…") { run(monitor.service(service, action)) }
                    }
                }
                Divider()
                Button("Journal en direct (terminal)", systemImage: "text.alignleft") {
                    if let error = model.ssh.openTerminal(host.alias, remote: RemoteActions.serviceLogs(service.name)) { model.launchError = error }
                }
            }
        }
        .padding(.vertical, 2).padding(.horizontal, 4)
        }
    }

    // MARK: Docker

    private var dockerCard: some View {
        let running = monitor.containers.filter(\.running).count
        return Card(title: String(localized: "Conteneurs Docker"), trailing: monitor.dockerAvailability == .available ? String(localized: "\(running) sur \(monitor.containers.count) en marche") : nil) {
            switch monitor.dockerAvailability {
            case .absent:
                Text("Docker n’est pas installé.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            case .denied:
                Text(String(localized: "Docker est installé, mais \(monitor.info?.login ?? String(localized: "cet utilisateur")) n’y a pas accès (groupe « docker »). Les actions passeront par sudo."))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            case nil:
                Text("Lecture des conteneurs…").font(.system(size: 12)).foregroundStyle(Theme.muted)
            case .available:
                if monitor.containers.isEmpty {
                    Text("Aucun conteneur.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                ForEach(monitor.containers) { container in containerRow(container) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func containerRow(_ container: RemoteContainer) -> some View {
        HoverRow { hovering in
        HStack(spacing: 8) {
            Circle().fill(container.running ? Theme.green : Theme.muted.opacity(0.5)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(container.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("\(container.image) · \(container.status)").font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let cpu = container.cpu, container.running {
                Text(Format.percent(cpu, decimals: 1)).font(.system(size: 11)).monospacedDigit().frame(width: 46, alignment: .trailing)
            }
            if let memory = container.memory, container.running {
                Text(memory.split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? memory)
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit().frame(width: 70, alignment: .trailing)
            }
            HoverMenu(hovering: hovering) {
                ForEach(RemoteActions.ServiceAction.allCases, id: \.self) { action in
                    if action == .start ? !container.running : (action == .stop ? container.running : container.running) {
                        Button("\(action.label)…") { run(monitor.container(container, action)) }
                    }
                }
                Divider()
                Button("Journaux en direct (terminal)", systemImage: "text.alignleft") {
                    if let error = model.ssh.openTerminal(host.alias, remote: RemoteActions.containerLogs(container.name)) { model.launchError = error }
                }
            }
        }
        .padding(.vertical, 2).padding(.horizontal, 4)
        }
    }

    // MARK: Ports

    private var portsCard: some View {
        Card(title: String(localized: "Ports en écoute (TCP)"), trailing: monitor.ports.isEmpty ? nil : String(localized: "\(monitor.ports.filter(\.exposed).count) ouverts sur le réseau")) {
            if monitor.portsAvailability == .absent {
                Text("ss n’est pas disponible sur ce serveur.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            ForEach(monitor.ports) { port in
                HStack(spacing: 8) {
                    Text(":\(String(port.port))").font(.system(size: 12, weight: .bold).monospaced()).frame(width: 64, alignment: .leading)
                    Text(port.process ?? "autre utilisateur (root)").font(.system(size: 12)).lineLimit(1)
                        .foregroundStyle(port.process == nil ? Theme.muted : .primary)
                    Spacer()
                    Text(port.exposed ? String(localized: "réseau") : String(localized: "local seulement")).font(.system(size: 11)).foregroundStyle(port.exposed ? Theme.orange : Theme.muted)
                }
                .contextMenu {
                    Button(String(localized: "Copier « \(host.hostName ?? host.alias):\(String(port.port)) »")) { copy("\(host.hostName ?? host.alias):\(String(port.port))") }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: Outils

    private func run(_ route: RemoteMonitorStore.Route) {
        switch route {
        case .plan(let plan): model.preview(plan)
        case .terminal(let command, let reason): terminalRequest = TerminalRequest(command: command, reason: reason)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86_400 { return String(localized: "\(s / 3600) h \(s % 3600 / 60) min") }
        return String(localized: "\(s / 86_400) j \(s % 86_400 / 3600) h")
    }
}

/// Bouton « … » d'une ligne : le vrai menu n'est créé qu'au survol (une centaine de menus
/// toujours présents coûtaient cher à chaque mesure).
struct HoverMenu<Items: View>: View {
    let hovering: Bool
    @ViewBuilder var items: () -> Items

    var body: some View {
        Group {
            if hovering {
                Menu { items() } label: { Image(systemName: "ellipsis").frame(width: 26, height: 20) }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(BareButtonStyle()).fixedSize()
            } else {
                Image(systemName: "ellipsis").foregroundStyle(Theme.muted.opacity(0.5)).frame(width: 26, height: 20)
            }
        }
        .frame(width: 28)
    }
}

/// Ligne qui sait si la souris la survole.
struct HoverRow<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @ViewState private var hovering = false

    var body: some View {
        content(hovering)
            .background(hovering ? Theme.hairline.opacity(0.6) : .clear, in: .rect(cornerRadius: 6))
            .onHover { hovering = $0 }
    }
}

/// Évalue son contenu dans son propre `body` : les données observées n'invalident que cette section.
struct Tracked<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View { content() }
}
