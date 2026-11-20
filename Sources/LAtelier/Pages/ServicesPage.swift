import LAtelierCore
import SwiftUI

/// Paquets › Services : `brew services` (postgres, redis, nginx…), état, port, mémoire, logs.
struct ServicesPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var openLogs: String?

    var body: some View {
        let store = model.services
        let services = store.value ?? []
        PageScaffold(page: .services, subtitle: subtitle(services)) {
            Button("Actualiser", systemImage: "arrow.clockwise") { model.scanServices() }
                .buttonStyle(.secondary)
                .disabled(store.loading)
            Button("Tout arrêter") {
                if let plan = BrewServices.stopAll(services) { model.preview(plan) }
            }
            .buttonStyle(.secondary)
            .disabled(!services.contains { $0.running && !$0.runsAsRoot })
        } content: {
            if store.value == nil {
                ScanningCard(label: "Lecture de brew services…")
            } else if services.isEmpty {
                Card { EmptyState(symbol: "server.rack", title: "Aucun service", message: "Aucune formule Homebrew installée ne fournit de service.") }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(services.enumerated()), id: \.element.id) { index, service in
                        if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                        ServiceRow(
                            service: service, summary: summary(of: service),
                            logsOpen: openLogs == service.name,
                            toggleLogs: { openLogs = openLogs == service.name ? nil : service.name }
                        )
                    }
                }
                .clipShape(.rect(cornerRadius: 22, style: .continuous))
                .cardBackground()
            }
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.orange)
            }
            Text("Les conteneurs Docker sont gérés dans Stockage › Docker. Un service qui occupe un port apparaît aussi dans Performance › Réseau.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        }
        .onAppear {
            if store.stale && !store.loading { model.scanServices() }
            if model.packages.stale && !model.packages.scanning { model.scanPackages() }
        }
        .onChange(of: store.stale) { _, stale in if stale && !store.loading { model.scanServices() } }
    }

    private func subtitle(_ services: [BrewService]) -> String {
        guard model.services.value != nil else { return "brew services et agents de dev" }
        let running = services.filter(\.running).count
        return "\(running) en cours sur \(services.count) · brew services et agents de dev"
    }

    private func summary(of service: BrewService) -> String {
        let desc = model.packages.packages.first { $0.source == .homebrew && !$0.isCask && $0.identifier == service.name }?.summary
        return ["Homebrew", desc].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct ServiceRow: View {
    @Environment(AppModel.self) private var model
    let service: BrewService
    let summary: String
    let logsOpen: Bool
    let toggleLogs: () -> Void

    var body: some View {
        let busy = model.serviceBusy.contains(service.name)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Circle()
                    .fill(dot)
                    .frame(width: 10, height: 10)
                    .padding(4)
                    .background(dot.opacity(0.2), in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.name).font(.system(size: 14, weight: .semibold))
                    Text(summary).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(stateLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(service.running ? Tag.green.0 : service.failed ? Theme.red : Theme.muted)
                    .frame(width: 110, alignment: .leading)
                Text(service.running && !service.ports.isEmpty ? service.ports.map { ":\($0)" }.joined(separator: " ") : "—")
                    .font(.system(size: 12).monospaced())
                    .frame(width: 80, alignment: .leading)
                Text(service.memory.map(Format.ram) ?? "")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .frame(width: 64, alignment: .trailing)
                Toggle("Au démarrage", isOn: Binding(
                    get: { service.registered },
                    set: { _ in model.preview(BrewServices.toggleAtLogin(service)) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 12))
                .disabled(!service.running || service.runsAsRoot || busy)
                .help(service.running ? "Relancer ce service à chaque ouverture de session" : "Démarrez d’abord le service")
                .frame(width: 130)
                Group {
                    if busy {
                        ProgressView().controlSize(.small).frame(width: 86)
                    } else if service.running {
                        Button("Arrêter") { model.runService(.stop, service) }.buttonStyle(.small)
                    } else {
                        Button("Démarrer") { model.runService(.start, service) }
                            .buttonStyle(PillButtonStyle(kind: .smallFilled))
                    }
                }
                .disabled(service.runsAsRoot)
                .help(service.runsAsRoot ? "Lancé avec sudo : à piloter dans le terminal" : "")
                Button(logsOpen ? "Masquer" : "Logs", action: toggleLogs).buttonStyle(.small)
            }
            if logsOpen {
                ConsoleBlock(text: BrewServices.logTail(service), color: Color(hex: 0xB9F5C9), maxHeight: 200)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
    }

    private var dot: Color {
        service.running ? Color(hex: 0x1E8A45) : service.failed ? Theme.red : Color(hex: 0x8E8E96)
    }

    private var stateLabel: String {
        if service.runsAsRoot && !service.running { return "Arrêté (root)" }
        if service.running { return service.runsAsRoot ? "En cours (root)" : "En cours" }
        if service.failed { return "Erreur (code \(service.exitCode ?? 0))" }
        return "Arrêté"
    }
}
