import LAtelierCore
import SwiftUI

/// Performance › Réseau : débit, ports en écoute (et leur exposition), trafic par processus.
struct NetworkPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var onlyExposed = false

    var body: some View {
        let monitor = model.performance
        PageScaffold(page: .reseau, subtitle: subtitle(monitor)) {
            content(monitor)
        }
        .onAppear {
            monitor.attach()
            model.ensureRepos()
            if model.services.stale && !model.services.loading { model.scanServices() }
        }
        .onDisappear { monitor.detach() }
    }

    private func subtitle(_ monitor: PerformanceMonitor) -> String {
        guard let network = monitor.latest?.network else { return String(localized: "Débit, ports ouverts et trafic par processus") }
        var parts = [network.primaryName ?? network.primaryInterface ?? String(localized: "Hors ligne")]
        if let address = network.localAddress { parts.append(String(localized: "adresse locale \(address)")) }
        parts.append(network.vpnActive ? String(localized: "VPN actif") : String(localized: "VPN inactif"))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func content(_ monitor: PerformanceMonitor) -> some View {
        if let sample = monitor.latest {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                StatTile(label: String(localized: "Réception"), value: Format.rate(sample.networkIn))
                StatTile(label: String(localized: "Envoi"), value: Format.rate(sample.networkOut))
                StatTile(label: String(localized: "Depuis le démarrage"),
                         value: monitor.bootTraffic.map { "↓ \(Format.total($0.read)) · ↑ \(Format.total($0.written))" } ?? "—")
                    .help(monitor.bootTime.map { String(localized: "Démarré ") + $0.formatted(.relative(presentation: .named).locale(Locale.current)) } ?? "")
                StatTile(label: String(localized: "Ports en écoute"), value: "\(monitor.ports.count)")
            }
            portsCard(monitor)
            trafficCard(monitor)
        } else {
            ScanningCard(label: String(localized: "Première mesure…"))
        }
    }

    // MARK: Ports

    private func portsCard(_ monitor: PerformanceMonitor) -> some View {
        let describer = PortDescriber(model: model, monitor: monitor)
        let ports = PortDescriber.sorted(monitor.ports).filter { !onlyExposed || $0.exposed }
        return VStack(spacing: 0) {
            HStack {
                Text("Ports en écoute").font(.system(size: 15, weight: .semibold))
                Spacer()
                Toggle(String(localized: "Seulement ceux exposés au réseau"), isOn: $onlyExposed)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Theme.raised.opacity(0.35))

            if ports.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Text(onlyExposed ? String(localized: "Aucun port exposé au réseau local.") : String(localized: "Aucun port ouvert par vos processus."))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
            ForEach(ports) { port in
                Rectangle().fill(Theme.hairline).frame(height: 1)
                PortRow(port: port, info: describer.describe(port, withScope: false), process: monitor.process(port.pid))
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text(String(localized: "Seuls vos processus sont listés : les ports ouverts par le système ou d’autres comptes demandent des droits admin."))
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .cardBackground()
    }

    // MARK: Trafic

    private func trafficCard(_ monitor: PerformanceMonitor) -> some View {
        let rates: [TrafficItem] = Array(monitor.traffic
            .map { TrafficItem(pid: $0.key, rate: $0.value) }
            .filter { $0.total > 0 }
            .sorted { $0.total > $1.total }
            .prefix(8))
        let top: Double = max(rates.first?.total ?? 1, 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Trafic par processus").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("mesuré toutes les 5 s").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            .padding(.bottom, 4)
            if !monitor.trafficReady {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Mesure en cours (5 secondes)…").font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
            } else if rates.isEmpty {
                Text("Aucun échange réseau ces dernières secondes.").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            ForEach(rates, id: \.pid) { item in
                let process = monitor.process(item.pid)
                let total = item.total
                HStack(spacing: 14) {
                    HStack(spacing: 8) {
                        ProcessIcon(name: process?.displayName ?? item.rate.name, bundle: process?.appBundle)
                        Text(process?.displayName ?? item.rate.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    }
                    .frame(width: 190, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.hairline)
                            Capsule().fill(Theme.accent).frame(width: max(4, geometry.size.width * total / top))
                        }
                    }
                    .frame(height: 8)
                    .accessibilityHidden(true)
                    Text("↓ \(Format.rate(item.rate.down)) · ↑ \(Format.rate(item.rate.up))")
                        .font(.system(size: 12).monospaced())
                        .lineLimit(1)
                        .frame(width: 190, alignment: .leading)
                    Text(destinations(monitor.connections[item.pid]))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                        .frame(width: 200, alignment: .leading)
                }
                .frame(minHeight: 34)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    /// Adresses seulement : pas de résolution DNS inverse (aucune requête réseau de plus).
    private func destinations(_ connections: ProcessConnections?) -> String {
        guard let connections, connections.count > 0 else { return "" }
        let hosts = connections.hosts.count
        let first = connections.hosts.first.map { " · \($0)" } ?? ""
        return String(localized: "\(connections.count) connexion\(connections.count > 1 ? "s" : "") vers \(hosts) hôte\(hosts > 1 ? "s" : "")")
            + (hosts == 1 ? first : "")
    }
}

private struct TrafficItem {
    let pid: Int32
    let rate: TrafficSampler.Rate
    var total: Double { rate.down + rate.up }
}

private struct PortRow: View {
    @Environment(AppModel.self) private var model
    let port: ListeningPort
    let info: PortDescriber.Info
    let process: RunningProcess?

    var body: some View {
        HStack(spacing: 16) {
            Text(":\(String(port.port))").font(.system(size: 14, weight: .bold).monospaced()).frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(info.process) · PID \(port.pid)").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(info.note).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(port.displayAddress).font(.system(size: 12).monospaced()).frame(width: 120, alignment: .leading)
                .help(port.addresses.joined(separator: ", "))
            Group {
                if port.exposed {
                    Tag(text: String(localized: "Exposé au réseau local"), foreground: Tag.orange.0, background: Tag.orange.1)
                        .help(String(localized: "Joignable par les autres appareils du réseau (adresse 0.0.0.0 ou ::). Un serveur de dev devrait écouter sur 127.0.0.1."))
                } else {
                    Tag(text: String(localized: "Local uniquement"), foreground: Tag.green.0, background: Tag.green.1)
                }
            }
            .frame(width: 160, alignment: .leading)
            PortActions(port: port).fixedSize().frame(width: 150, alignment: .trailing)
            Group {
                if let process, process.canQuit {
                    Button(String(localized: "Libérer le port")) {
                        model.quit([process.target], label: info.process, force: false,
                                   reason: String(localized: "Le port \(String(port.port)) sera libéré quand le processus aura quitté."))
                    }
                    .buttonStyle(.small)
                } else {
                    Text("système").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            .frame(width: 120, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .portContextMenu(port)
        .onTapGesture(count: 2) { model.processDetail = ProcessDetailRequest(pid: port.pid) }
    }
}
