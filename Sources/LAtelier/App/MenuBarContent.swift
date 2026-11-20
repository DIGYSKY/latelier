import AppKit
import LAtelierCore
import SwiftUI

/// Menu de la barre des menus, dans le style de l'app : fond dégradé, cartes en verre.
/// Ressources en direct, processus gourmands, ce qui est à traiter, ports, raccourcis.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let monitor = model.performance
        VStack(alignment: .leading, spacing: 10) {
            header
            if let sample = monitor.latest {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    tile("Processeur", Format.percent(sample.cpu), "perf. \(Format.percent(sample.performanceLoad)) · eff. \(Format.percent(sample.efficiencyLoad))",
                         monitor.cpuHistory, max: 100, color: Theme.accent)
                    tile("Mémoire", Format.ram(sample.memory.used), "sur \(Format.ram(sample.memory.total)) · \(sample.memory.pressure.label)",
                         monitor.memoryHistory, max: Double(sample.memory.total), color: Color(hex: 0x6E4BD8))
                    tile("Disque", freeSpace.map { "\(Format.bytes($0.0)) libres" } ?? "—",
                         "\(Format.rate(sample.diskRead)) ↓ · \(Format.rate(sample.diskWrite)) ↑", monitor.diskHistory, color: Color(hex: 0x00879E))
                    tile("Réseau", "\(Format.rate(sample.networkIn)) ↓", "\(Format.rate(sample.networkOut)) ↑ · \(sample.network.primaryName ?? "hors ligne")",
                         monitor.networkHistory, color: Color(hex: 0x1E8A45))
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Première mesure…").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .cardBackground(radius: 16)
            }
            heavyProcesses(monitor)
            alertsCard
            portsCard(monitor)
            shortcuts
            footer
        }
        .padding(12)
        .frame(width: 380)
        .background { Backdrop(glass: model.preferences.glass) }
        .onAppear { monitor.attach() }
        .onDisappear { monitor.detach() }
    }

    // MARK: En-tête

    private var header: some View {
        let count = alerts.count
        return HStack(spacing: 10) {
            Image(systemName: "wrench.adjustable")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Theme.accent, in: .rect(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("L’Atelier").font(.system(size: 15, weight: .bold))
                Text(count == 0 ? "Rien à signaler" : "\(count) point\(count > 1 ? "s" : "") à traiter")
                    .font(.system(size: 11)).foregroundStyle(count == 0 ? Theme.green : Theme.orange)
            }
            Spacer()
            Button { open(.accueil) } label: { Image(systemName: "macwindow") }
                .buttonStyle(PillButtonStyle(kind: .small)).help("Ouvrir L’Atelier")
            Button { open(.reglages) } label: { Image(systemName: "gearshape") }
                .buttonStyle(PillButtonStyle(kind: .small)).help("Réglages")
        }
    }

    // MARK: Tuiles

    private func tile(_ label: String, _ value: String, _ detail: String, _ history: [Double], max: Double? = nil, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 17, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.8)
            Sparkline(values: Array(history.suffix(60)), maxValue: max, color: color).frame(height: 24).padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(radius: 14)
    }

    // MARK: Processus

    private func heavyProcesses(_ monitor: PerformanceMonitor) -> some View {
        let top = monitor.processes.sorted { $0.cpu > $1.cpu }.prefix(4)
        return section("Processus les plus actifs", action: ("Tout voir", .processus)) {
            if top.isEmpty {
                Text("Mesure en cours…").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            ForEach(Array(top)) { process in
                Button {
                    open(.processus)
                    model.processDetail = ProcessDetailRequest(pid: process.pid)
                } label: {
                    HStack(spacing: 8) {
                        ProcessIcon(name: process.displayName, bundle: process.appBundle).frame(width: 18, height: 18)
                        Text(process.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Format.percent(process.cpu)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(process.cpu > 50 ? Theme.red : .primary)
                        Text(Format.ram(process.memory)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted)
                            .frame(width: 64, alignment: .trailing)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: À traiter

    private var alerts: [(text: String, symbol: String, color: Color, page: Page)] {
        var list: [(String, String, Color, Page)] = []
        let concerning = model.news.concerningSevere
        if concerning > 0 { list.append(("\(concerning) avis de sécurité vous concerne\(concerning > 1 ? "nt" : "")", "exclamationmark.shield", Theme.red, .pourVous)) }
        if let analysis = model.analysis.value {
            let critical = analysis.vulnerablePackages.filter { $0.severity == .critical }.count
            if critical > 0 { list.append(("\(critical) dépendance\(critical > 1 ? "s" : "") à faille critique", "lock.shield", Theme.red, .securite)) }
            if !analysis.secrets.isEmpty { list.append(("\(analysis.secrets.count) secret\(analysis.secrets.count > 1 ? "s" : "") commité\(analysis.secrets.count > 1 ? "s" : "")", "key", Theme.red, .securite)) }
        }
        let updates = model.packages.updates.count
        if updates > 0 { list.append(("\(updates) mise\(updates > 1 ? "s" : "") à jour de paquets", "arrow.down.circle", Theme.orange, .majs)) }
        let unpushed = model.repos.repos.filter { $0.ahead > 0 }.count
        if unpushed > 0 { list.append(("\(unpushed) dépôt\(unpushed > 1 ? "s" : "") avec des commits non poussés", "arrow.up.circle", Theme.accent, .modifications)) }
        if let free = freeSpace, Double(free.0) / Double(max(free.1, 1)) < 0.1 {
            list.append(("Espace disque faible : \(Format.bytes(free.0)) libres", "internaldrive", Theme.red, .stockageVue))
        }
        return list
    }

    private var alertsCard: some View {
        section("À traiter") {
            if alerts.isEmpty {
                Label("Rien à signaler", systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(Theme.green)
            }
            ForEach(alerts, id: \.text) { alert in
                Button { open(alert.page) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: alert.symbol).font(.system(size: 12)).foregroundStyle(alert.color).frame(width: 18)
                        Text(alert.text).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Ports

    @ViewBuilder
    private func portsCard(_ monitor: PerformanceMonitor) -> some View {
        let ports = PortDescriber.sorted(monitor.ports).filter { monitor.process($0.pid)?.isSystem == false }.prefix(4)
        if !ports.isEmpty {
            section("Ports en écoute", action: ("Réseau", .reseau)) {
                ForEach(Array(ports)) { port in
                    HStack(spacing: 8) {
                        Text(":\(String(port.port))").font(.system(size: 12, weight: .bold).monospaced()).frame(width: 58, alignment: .leading)
                        Text(monitor.process(port.pid)?.displayName ?? port.command).font(.system(size: 12)).lineLimit(1)
                        if port.exposed { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Theme.orange).help("Exposé au réseau local") }
                        Spacer(minLength: 4)
                        PortActions(port: port, compact: true).fixedSize().controlSize(.small)
                    }
                    .portContextMenu(port)
                }
            }
        }
    }

    // MARK: Raccourcis

    private var shortcuts: some View {
        HStack(spacing: 6) {
            shortcut("Stockage", "internaldrive", .stockageVue)
            shortcut("Projets", "folder.badge.gearshape", .depots)
            shortcut("Moniteur", "waveform.path.ecg.rectangle", .moniteur)
            shortcut("News", "newspaper", .pourVous)
        }
    }

    private func shortcut(_ label: String, _ symbol: String, _ page: Page) -> some View {
        Button { open(page) } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Theme.accent)
                Text(label).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .cardBackground(radius: 12)
    }

    private var footer: some View {
        HStack {
            Text("Mis à jour chaque seconde").font(.system(size: 10)).foregroundStyle(Theme.muted)
            Spacer()
            Button("Quitter L’Atelier") { NSApp.terminate(nil) }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 4)
    }

    // MARK: Outils

    private func section<Content: View>(_ title: String, action: (String, Page)? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                if let action {
                    Button(action.0) { open(action.1) }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.link)
                }
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(radius: 14)
    }

    private var freeSpace: (Int64, Int64)? {
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return (free, Int64(total))
    }

    private func open(_ page: Page) {
        model.selection = page
        if page == .depots { model.openRepo = nil }
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}
