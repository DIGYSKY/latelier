import AppKit
import LAtelierCore
import Observation

/// Enregistreur de performances : détecte les processus de dev lancés dans les projets
/// (sondage toutes les 2 s), les enregistre selon la politique choisie, garde les sessions.
@Observable
final class RecorderService {
    struct Live {
        var process: DetectedProcess
        var session: RecordingSession
        var sampler: TreeSampler
    }

    private(set) var detected: [DetectedProcess] = []
    private(set) var live: [String: Live] = [:]
    private(set) var sessions: [RecordingSession] = []
    /// Processus en attente de décision (« Me demander »).
    private(set) var pending: [DetectedProcess] = []
    /// Session affichée dans le graphique.
    var focus: String?

    @ObservationIgnored private var ignored: Set<String> = []
    @ObservationIgnored private var seen: Set<String> = []
    @ObservationIgnored private var armed: [String: (label: String, until: Date)] = [:]
    @ObservationIgnored private var detectLoop: Task<Void, Never>?
    @ObservationIgnored private var sampleLoop: Task<Void, Never>?
    @ObservationIgnored private let store = RecordingStore()
    @ObservationIgnored private let preferences: ToolPreferences
    @ObservationIgnored private let projects: () -> [URL]

    init(preferences: ToolPreferences, projects: @escaping () -> [URL]) {
        self.preferences = preferences
        self.projects = projects
    }

    func start() {
        Task { sessions = await store.all() }
        guard detectLoop == nil else { return }
        detectLoop = Task { [weak self] in
            while !Task.isCancelled {
                self?.detect()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        sampleLoop = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Détection

    private func detect() {
        let policy = preferences.recorderPolicy
        let list = projects()
        guard policy != .off || !armed.isEmpty, !list.isEmpty else {
            if !detected.isEmpty { detected = [] }
            return
        }
        let found = RecorderDetector.scan(projects: list)
        detected = found
        pending.removeAll { p in !found.contains { $0.id == p.id } }
        armed = armed.filter { $0.value.until > Date() }

        for process in found where !seen.contains(process.id) {
            seen.insert(process.id)
            let path = process.project.path
            if preferences.neverRecord.contains(path) { continue }
            if let arm = armed[path] {
                armed[path] = nil
                record(process, auto: true, name: arm.label)
            } else if policy == .auto || preferences.alwaysRecord.contains(path) {
                record(process, auto: true)
            } else if policy == .ask {
                pending.append(process)
            }
        }
    }

    /// « Exécuter et enregistrer » depuis Commandes : le prochain processus du projet est enregistré.
    func arm(project: URL, label: String) {
        armed[project.path] = (label, Date().addingTimeInterval(20))
    }

    func record(_ process: DetectedProcess, auto: Bool, name: String? = nil) {
        guard live[process.id] == nil else { return }
        pending.removeAll { $0.id == process.id }
        let start = Date(timeIntervalSince1970: TimeInterval(process.started))
        let session = RecordingSession(
            name: name ?? process.command, project: process.project.path, command: process.command,
            auto: auto, start: max(start, Date().addingTimeInterval(-1))
        )
        live[process.id] = Live(process: process, session: session, sampler: TreeSampler(root: process.target))
        focus = process.id
    }

    func always(_ process: DetectedProcess) {
        preferences.alwaysRecord.insert(process.project.path)
        record(process, auto: true)
    }

    func ignore(_ process: DetectedProcess) {
        ignored.insert(process.id)
        pending.removeAll { $0.id == process.id }
    }

    func isIgnored(_ process: DetectedProcess) -> Bool { ignored.contains(process.id) }

    func stop(_ id: String) {
        guard let entry = live.removeValue(forKey: id) else { return }
        save(entry.session)
        if focus == id { focus = live.keys.first }
    }

    func addMark(_ label: String = "Repère") {
        guard let id = focus ?? live.keys.first, var entry = live[id], let t = entry.session.samples.last?.t else { return }
        let count = entry.session.marks.filter { !$0.auto }.count + 1
        entry.session.marks.append(RecordingMark(t: t, label: label == "Repère" ? "Repère \(count)" : label, auto: false))
        live[id] = entry
    }

    // MARK: Mesure

    private func sample() {
        guard !live.isEmpty else { return }
        let now = Date()
        for (id, var entry) in live {
            guard let measure = entry.sampler.sample(now: now) else {
                // Le processus s'est terminé : la session est rangée avec le projet.
                live[id] = nil
                save(entry.session)
                if focus == id { focus = live.keys.first }
                continue
            }
            let t = now.timeIntervalSince(entry.session.start)
            entry.session.samples.append(RecordingSample(
                t: t, cpu: measure.cpu, memory: measure.memory, diskRead: measure.read, diskWrite: measure.write, processes: measure.processes
            ))
            if let mark = MarkDetector.detect(samples: entry.session.samples, marks: entry.session.marks) {
                entry.session.marks.append(mark)
            }
            live[id] = entry
        }
    }

    private func save(_ session: RecordingSession) {
        // Le premier point n'a pas de débit : une session utile en a au moins trois.
        guard session.samples.count >= 3 else { return }
        sessions.insert(session, at: 0)
        Task { try? await store.save(session) }
    }

    // MARK: Sessions

    func rename(_ session: RecordingSession, to name: String) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[index].name = name
        let updated = sessions[index]
        Task { try? await store.save(updated) }
    }

    func url(for session: RecordingSession) async -> URL { await store.url(for: session) }

    func reload() {
        Task { sessions = await store.all() }
    }

    /// Export JSON ou CSV, avec le panneau d'enregistrement de macOS.
    @MainActor
    func export(_ session: RecordingSession, csv: Bool) {
        let panel = NSSavePanel()
        let base = "\(session.projectName)-\(session.start.formatted(.iso8601.year().month().day()))"
        panel.nameFieldStringValue = base + (csv ? ".csv" : ".json")
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if csv {
                try session.csv().write(to: url, atomically: true, encoding: .utf8)
            } else {
                try session.json().write(to: url, options: .atomic)
            }
        } catch {
            NSSound.beep()
        }
    }
}
