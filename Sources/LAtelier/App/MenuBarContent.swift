import AppKit
import LAtelierCore
import SwiftUI

/// Icône de la barre des menus : CPU, mémoire, disque et alertes en un coup d'œil.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @ViewState private var sample: SystemSample?
    @ViewState private var sampler = SystemSampler()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("L’Atelier").font(.system(size: 14, weight: .bold))
                Spacer()
                Button("Ouvrir") { open(.accueil) }.buttonStyle(.link)
            }
            if let sample {
                row("cpu", "Processeur", Format.percent(sample.cpu))
                row("memorychip", "Mémoire", "\(Format.bytes(sample.memory.used)) sur \(Format.bytes(sample.memory.total))")
            } else {
                ProgressView().controlSize(.small)
            }
            if let free = freeSpace {
                row("internaldrive", "Disque", "\(Format.bytes(free.0)) libres sur \(Format.bytes(free.1))")
            }
            Divider()
            let alerts = alerts
            if alerts.isEmpty {
                Label("Rien à signaler", systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(alerts, id: \.0) { alert in
                Button { open(alert.2) } label: {
                    Label(alert.0, systemImage: alert.1).font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            Divider()
            HStack {
                Button("Réglages…") { open(.reglages) }.buttonStyle(.link)
                Spacer()
                Button("Quitter") { NSApp.terminate(nil) }.buttonStyle(.link)
            }
            .font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 280)
        .task {
            while !Task.isCancelled {
                sample = sampler.sample()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func row(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(label).font(.system(size: 12))
            Spacer()
            Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }
    }

    private var freeSpace: (Int64, Int64)? {
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return (free, Int64(total))
    }

    private var alerts: [(String, String, Page)] {
        var list: [(String, String, Page)] = []
        let concerning = model.news.visibleItems.filter { model.news.confirmed($0) && $0.isSevere && !model.news.isRead($0) }.count
        if concerning > 0 { list.append(("\(concerning) avis de sécurité vous concerne\(concerning > 1 ? "nt" : "")", "exclamationmark.shield", .pourVous)) }
        if let analysis = model.analysis.value {
            let serious = analysis.vulnerablePackages.filter { $0.severity >= .high }.count
            if serious > 0 { list.append(("\(serious) dépendance\(serious > 1 ? "s" : "") à faille grave", "lock.shield", .securite)) }
        }
        let updates = model.packages.updates.count
        if updates > 0 { list.append(("\(updates) mise\(updates > 1 ? "s" : "") à jour de paquets", "arrow.down.circle", .majs)) }
        return list
    }

    private func open(_ page: Page) {
        model.selection = page
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}
