import AppKit
import LAtelierCore
import Observation
import SwiftUI

/// Moniteur d'un serveur : une seule connexion SSH ouverte tant que l'onglet est affiché,
/// qui reçoit une mesure toutes les ~2 s. Rien n'est installé sur le serveur.
@Observable
final class RemoteMonitorStore {
    let alias: String
    private(set) var running = false
    private(set) var paused = false
    private(set) var error: (title: String, advice: String)?
    private(set) var latest: RemoteSample?
    /// Vrai dès la première mesure (change une seule fois : l'écran principal ne se redessine pas à chaque mesure).
    private(set) var hasSample = false
    private(set) var info: RemoteSystemInfo?
    private(set) var processes: [RemoteProcess] = []
    private(set) var disks: [RemoteDisk] = []
    private(set) var ports: [RemotePort] = []
    private(set) var services: [RemoteService] = []
    private(set) var containers: [RemoteContainer] = []
    private(set) var portsAvailability: RemoteAvailability?
    private(set) var servicesAvailability: RemoteAvailability?
    private(set) var dockerAvailability: RemoteAvailability?
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    private(set) var networkInHistory: [Double] = []
    private(set) var networkOutHistory: [Double] = []
    private(set) var diskReadHistory: [Double] = []
    private(set) var diskWriteHistory: [Double] = []

    @ObservationIgnored private var task: Task<Void, Never>?
    /// Lecture du flux (détachée) : annulée explicitement, ce qui ferme la connexion SSH.
    @ObservationIgnored private var reader: Task<(status: Int32?, errors: [String]), Never>?
    @ObservationIgnored private weak var store: SSHStore?
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var processTick = 0
    static let historyLength = 150 // 5 minutes à une mesure toutes les 2 s

    init(alias: String, store: SSHStore) {
        self.alias = alias
        self.store = store
    }

    // MARK: Connexion

    func attach() {
        viewers += 1
        if !paused { start() }
    }

    func detach() {
        viewers = max(0, viewers - 1)
        // Petit délai : changer d'onglet et revenir ne relance pas la connexion.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.viewers == 0 else { return }
            self.stop()
        }
    }

    func togglePause() {
        paused.toggle()
        paused ? stop() : start()
    }

    func retry() {
        error = nil
        start()
    }

    private func start() {
        guard task == nil else { return }
        running = true
        error = nil
        let spec = SSHCommands(alias: alias).ssh(RemoteMonitorScript.remoteCommand)
        let runner = store?.commandRunner ?? CommandRunner()
        task = Task { [weak self] in
            // Lecture et analyse hors du fil principal (≈ 1 000 lignes toutes les 2 s) :
            // seule la mesure complète revient à l'interface.
            let reader = Task.detached(priority: .utility) { () -> (status: Int32?, errors: [String]) in
                var parser = RemoteMonitorParser()
                var errors: [String] = []
                var status: Int32?
                do {
                    for try await event in runner.stream(spec) {
                        switch event {
                        case .stdout(let line):
                            if let snapshot = parser.feed(line) {
                                await MainActor.run { self?.apply(snapshot) }
                            }
                        case .stderr(let line):
                            if errors.count < 50 { errors.append(line) }
                        case .exited(let code, _):
                            status = code
                        }
                    }
                } catch {
                    errors.append(error.localizedDescription)
                }
                return (status, errors)
            }
            self?.reader = reader
            let outcome = await reader.value
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            self.running = false
            if outcome.status != 0 || !self.hasSample {
                let text = outcome.errors.joined(separator: "\n")
                self.error = SSHFailure.explain(text.isEmpty ? String(localized: "La connexion s’est fermée.") : text)
                self.store?.noteResult(self.alias, ok: false, output: text)
            }
        }
    }

    func stop() {
        reader?.cancel()
        reader = nil
        task?.cancel()
        task = nil
        running = false
    }

    /// N'écrit que ce qui a changé : chaque écriture redessine les sections qui l'affichent.
    private func apply(_ snapshot: RemoteSnapshot) {
        if latest == nil { store?.noteResult(alias, ok: true, output: "") }
        if let info = snapshot.info, info != self.info { self.info = info }
        if let sample = snapshot.sample {
            latest = sample
            if !hasSample { hasSample = true }
            Self.push(&cpuHistory, sample.cpu)
            Self.push(&memoryHistory, Double(sample.memoryUsed))
            Self.push(&networkInHistory, sample.networkIn)
            Self.push(&networkOutHistory, sample.networkOut)
            Self.push(&diskReadHistory, sample.diskRead)
            Self.push(&diskWriteHistory, sample.diskWrite)
        }
        // La liste des processus suit toutes les 4 s (les graphiques, toutes les 2 s) : elle coûte le plus à redessiner.
        processTick += 1
        if !snapshot.processes.isEmpty, processes.isEmpty || processTick % 2 == 0, snapshot.processes != processes { processes = snapshot.processes }
        if let disks = snapshot.disks, disks != self.disks { self.disks = disks }
        if let ports = snapshot.ports, ports != self.ports { self.ports = ports }
        if let services = snapshot.services, services != self.services { self.services = services }
        if let containers = snapshot.containers, containers != self.containers { self.containers = containers }
        if let value = snapshot.portsAvailability, value != portsAvailability { portsAvailability = value }
        if let value = snapshot.servicesAvailability, value != servicesAvailability { servicesAvailability = value }
        if let value = snapshot.dockerAvailability, value != dockerAvailability { dockerAvailability = value }
    }

    private static func push(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }

    // MARK: Actions (toujours avec aperçu)

    /// Ce qu'une action demande : directement (avec aperçu), ou dans le terminal avec sudo (mot de passe tapé par vous).
    enum Route {
        case plan(ActionPlan)
        case terminal(command: String, reason: String)
    }

    private var login: String { info?.login ?? "" }
    private var isRoot: Bool { info?.isRoot ?? false }
    private var canSudo: Bool { info?.canSudo ?? false }

    func stopProcess(_ process: RemoteProcess, force: Bool) -> Route {
        let own = process.user == login || isRoot
        let verb = force ? String(localized: "Forcer l’arrêt de") : String(localized: "Arrêter")
        if !own && !canSudo {
            return .terminal(command: "sudo sh -c " + ShellQuote.quote(RemoteActions.kill(process, force: force, sudo: false)),
                             reason: String(localized: "« \(process.name) » appartient à \(process.user) : il faut les droits administrateur. La commande s’ouvre dans le terminal, où sudo vous demandera votre mot de passe."))
        }
        let command = RemoteActions.kill(process, force: force, sudo: !own && !isRoot)
        return .plan(ActionPlan(
            title: String(localized: "\(verb) « \(process.name) » (PID \(String(process.pid))) sur \(alias)"),
            summary: (force ? String(localized: "SIGKILL : arrêt immédiat, sans laisser le programme enregistrer son travail. ") : String(localized: "SIGTERM : le programme est prié de s’arrêter proprement. "))
                + String(localized: "Avant d’envoyer le signal, L’Atelier vérifie que le PID désigne toujours ce processus."),
            kind: .serveur, risk: force ? .danger : .caution, reversible: false,
            steps: [.command(SSHCommands(alias: alias).ssh(command))]
        ))
    }

    func service(_ service: RemoteService, _ action: RemoteActions.ServiceAction) -> Route {
        if !isRoot && !canSudo {
            return .terminal(command: "sudo " + RemoteActions.service(service.name, action, sudo: false),
                             reason: String(localized: "Piloter un service systemd demande les droits administrateur. La commande s’ouvre dans le terminal, où sudo vous demandera votre mot de passe."))
        }
        return .plan(ActionPlan(
            title: String(localized: "\(action.label) le service « \(service.name) » sur \(alias)"),
            summary: action == .stop ? String(localized: "Le service s’arrête jusqu’au prochain démarrage (ou jusqu’à ce que vous le relanciez).") : String(localized: "Le service est \(action == .restart ? String(localized: "relancé") : String(localized: "démarré")) par systemd."),
            kind: .serveur, risk: action == .stop ? .caution : .safe, reversible: action != .stop,
            steps: [.command(SSHCommands(alias: alias).ssh(RemoteActions.service(service.name, action, sudo: !isRoot)))]
        ))
    }

    func container(_ container: RemoteContainer, _ action: RemoteActions.ServiceAction) -> Route {
        let direct = dockerAvailability == .available
        if !direct && !canSudo {
            return .terminal(command: "sudo " + RemoteActions.container(container.name, action, sudo: false),
                             reason: String(localized: "\(login.isEmpty ? String(localized: "Cet utilisateur") : login) n’a pas accès à Docker. La commande s’ouvre dans le terminal, où sudo vous demandera votre mot de passe."))
        }
        return .plan(ActionPlan(
            title: String(localized: "\(action.label) le conteneur « \(container.name) » sur \(alias)"),
            summary: String(localized: "Image \(container.image). ") + (action == .stop ? String(localized: "Le conteneur s’arrête ; ses données (volumes) restent.") : String(localized: "Docker \(action == .restart ? String(localized: "redémarre") : String(localized: "démarre")) le conteneur.")),
            kind: .serveur, risk: action == .stop ? .caution : .safe, reversible: action != .stop,
            steps: [.command(SSHCommands(alias: alias).ssh(RemoteActions.container(container.name, action, sudo: !direct)))]
        ))
    }
}
