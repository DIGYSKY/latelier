import Foundation
import LAtelierCore
import Observation

/// Exécution des commandes de projet (Projets › Commandes) : sortie en direct, arrêt, dernier résultat.
@Observable
final class CommandCenter {
    struct LiveRun {
        var project: URL
        var command: ProjectCommand
        var lines: [String] = []
        var start = Date()
        var end: Date?
        var status: Int32?
        var stopped = false

        var running: Bool { end == nil }
        var stateLabel: String {
            if running { return String(localized: "En cours") }
            if stopped { return String(localized: "Arrêté") }
            return status == 0 ? String(localized: "Terminé") : String(localized: "Échec")
        }
    }

    private(set) var state = CommandState()
    private(set) var runs: [String: LiveRun] = [:]
    /// Exécution affichée dans le panneau de sortie.
    var focus: String?
    private(set) var sets: [URL: ProjectCommandSet] = [:]

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let store = JSONStore<CommandState>(name: "commands.json", fallback: CommandState())
    @ObservationIgnored private let runner: CommandRunner
    @ObservationIgnored private let onFinish: (HistoryEntry) async -> Void
    static let maxLines = 2000

    init(runner: CommandRunner, onFinish: @escaping (HistoryEntry) async -> Void) {
        self.runner = runner
        self.onFinish = onFinish
        Task { state = await store.load() }
    }

    func commands(for project: URL) -> ProjectCommandSet {
        if let cached = sets[project] { return cached }
        let set = ProjectCommandDetector.detect(project, locator: runner.locator)
        sets[project] = set
        return set
    }

    /// Relit les fichiers du projet (après l'ajout d'un script par exemple).
    func reload(_ project: URL? = nil) {
        if let project { sets[project] = nil } else { sets = [:] }
    }

    func key(_ project: URL, _ command: ProjectCommand) -> String { CommandState.key(project, command) }

    func isRunning(_ key: String) -> Bool { runs[key]?.running == true }

    func lastRun(_ project: URL, _ command: ProjectCommand) -> CommandRunRecord? { state.runs[key(project, command)] }

    func togglePin(_ project: URL, _ command: ProjectCommand) {
        let k = key(project, command)
        if state.pins.contains(k) { state.pins.remove(k) } else { state.pins.insert(k) }
        save()
    }

    func isPinned(_ project: URL, _ command: ProjectCommand) -> Bool { state.pins.contains(key(project, command)) }

    func dismiss(_ project: URL, id: String) {
        state.dismissed.insert(CommandState.key(project, id))
        save()
    }

    func isDismissed(_ project: URL, _ id: String) -> Bool { state.dismissed.contains(CommandState.key(project, id)) }

    /// Projets où une commande a été lancée, du plus récent au plus ancien.
    var recentProjects: [URL] {
        var latest: [String: Date] = [:]
        for (key, run) in state.runs {
            let path = String(key.prefix { $0 != "#" })
            latest[path] = max(latest[path] ?? .distantPast, run.date)
        }
        return latest.sorted { $0.value > $1.value }.map { URL(fileURLWithPath: $0.key) }
    }

    /// Lance la commande (non sensible) avec la sortie en direct.
    func start(_ command: ProjectCommand, in project: URL) {
        let k = key(project, command)
        guard !isRunning(k) else { return }
        runs[k] = LiveRun(project: project, command: command, lines: ["$ cd \(project.abbreviatingHome())", "$ \(command.commandLine)"])
        focus = k
        let spec = command.spec
        let runner = runner
        tasks[k] = Task { [weak self] in
            var status: Int32?
            var launchError: String?
            do {
                for try await event in runner.stream(spec) {
                    guard let self else { return }
                    switch event {
                    case .stdout(let line), .stderr(let line): self.append(line, to: k)
                    case .exited(let code, let signaled): status = signaled ? nil : code
                    }
                }
            } catch is CancellationError {
            } catch {
                launchError = error.localizedDescription
                self?.append(error.localizedDescription, to: k)
            }
            await self?.finish(k, status: launchError == nil ? status : 127)
        }
    }

    func stop(_ key: String) {
        runs[key]?.stopped = true
        tasks[key]?.cancel()
    }

    private func append(_ line: String, to key: String) {
        guard var run = runs[key] else { return }
        run.lines.append(line)
        if run.lines.count > Self.maxLines { run.lines.removeFirst(run.lines.count - Self.maxLines) }
        runs[key] = run
    }

    private func finish(_ key: String, status: Int32?) async {
        guard var run = runs[key] else { return }
        // Le flux annulé ne rend pas de statut : c'est un arrêt demandé.
        if Task.isCancelled || status == nil { run.stopped = true }
        run.end = Date()
        run.status = status
        let duration = run.end!.timeIntervalSince(run.start)
        run.lines.append(run.stopped ? String(localized: "■ Arrêté après \(Format.duration(duration))") : (status == 0 ? String(localized: "✓ Terminé en \(Format.duration(duration))") : String(localized: "✗ Échec (code \(status.map(String.init) ?? "?"))")))
        runs[key] = run
        tasks[key] = nil

        let failed = !run.stopped && status != 0
        state.runs[key] = CommandRunRecord(date: run.start, status: run.stopped ? nil : status, duration: duration,
                                           errorTail: failed ? Array(run.lines.suffix(40)) : [])
        if failed, CommandState.busyPort(in: run.lines.suffix(60).map { $0 }) != nil {
            state.portFailures[key, default: 0] += 1
        }
        save()

        let output = run.lines.dropFirst(2).suffix(400).joined(separator: "\n")
        let entry = HistoryEntry(
            kind: .commande, title: "\(run.command.name) dans \(run.project.lastPathComponent)",
            summary: String(localized: "Commande du projet (\(run.command.source))."),
            commands: [CommandLog(command: run.command.spec.displayString, exitStatus: run.stopped ? nil : status, output: output, duration: duration)],
            outcome: run.stopped ? .cancelled : (status == 0 ? .success : .failure(String(localized: "« \(run.command.commandLine) » a échoué (code \(status.map(String.init) ?? "?"))."))),
            bytesFreed: nil
        )
        await onFinish(entry)
    }

    private func save() {
        let snapshot = state
        Task { try? await store.save(snapshot) }
    }

    /// Port occupé lors du dernier échec d'une commande de ce projet.
    func busyPort(in project: URL) -> (command: String, port: Int)? {
        for (key, record) in state.runs where key.hasPrefix(project.path + "#") && !record.errorTail.isEmpty {
            if let port = CommandState.busyPort(in: record.errorTail) {
                return (String(key.split(separator: ":").last ?? ""), port)
            }
        }
        return nil
    }

    /// Plan d'exécution pour une commande sensible : aperçu obligatoire.
    static func sensitivePlan(_ command: ProjectCommand, project: URL) -> ActionPlan {
        ActionPlan(
            title: String(localized: "Lancer « \(command.name) » dans \(project.lastPathComponent)"),
            summary: String(localized: "Commande sensible (déploiement, migration ou suppression) : vérifiez-la avant de la lancer."),
            kind: .commande, risk: .danger, reversible: false, commands: [command.spec]
        )
    }

    /// Ajout d'un script proposé par une suggestion.
    static func suggestionPlan(_ suggestion: CommandSuggestion, project: URL) -> ActionPlan? {
        guard let edit = suggestion.edit else { return nil }
        return ActionPlan(
            title: suggestion.title,
            summary: String(localized: "\(suggestion.why) La ligne est ajoutée au bloc « scripts » de \(edit.file.lastPathComponent), le reste du fichier ne change pas."),
            kind: .commande, risk: .safe, reversible: false, steps: [.editFile(edit)]
        )
    }
}
