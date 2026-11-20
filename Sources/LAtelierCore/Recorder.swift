import Darwin
import Foundation

/// Que faire quand un processus de dev démarre dans un projet.
public enum RecorderPolicy: String, Sendable, CaseIterable, Codable {
    case auto, ask, off

    public var label: String {
        switch self {
        case .auto: "Enregistrer automatiquement"
        case .ask: "Me demander"
        case .off: "Désactivé"
        }
    }
}

/// Un processus de dev qui tourne dans un projet connu (racine de son arbre).
public struct DetectedProcess: Sendable, Identifiable, Hashable {
    public var pid: Int32
    public var started: UInt64
    public var project: URL
    public var name: String
    /// Ligne de commande (« npm run dev »).
    public var command: String
    public var children: Int
    /// Lancé depuis L’Atelier (Projets › Commandes).
    public var fromAtelier: Bool

    public var id: String { "\(pid):\(started)" }
    public var target: ProcessTarget { ProcessTarget(pid: pid, name: name, started: started) }
}

/// Mémoire de la détection : processus déjà écartés, oubliés quand ils se terminent
/// ou quand la liste des projets change.
public final class RecorderScanCache: @unchecked Sendable {
    var rejected: [Int32: UInt64] = [:]
    private var projectsKey: [String] = []

    public init() {}

    func reset(ifProjectsChanged projects: [URL]) {
        let key = projects.map(\.path).sorted()
        if key != projectsKey {
            projectsKey = key
            rejected = [:]
        }
    }
}

public enum RecorderDetector {
    static let ignored: Set<String> = [
        "zsh", "-zsh", "bash", "-bash", "fish", "sh", "login", "tmux", "screen", "git", "ssh", "less", "vim", "nvim", "nano",
        "lsof", "ps", "nettop", "sfltool", "launchctl", "osascript", "claude",
    ]

    static let helperDirectories = [".claude/", ".vscode/", ".cursor/", ".windsurf/", ".zed/", "Library/Application Support/"]

    /// Processus de l'utilisateur dont le dossier de travail est dans un projet, lancés depuis au moins `minimumAge` s.
    /// `cache` retient les processus déjà écartés (PID + date de lancement) : à chaque passage, seuls
    /// les nouveaux processus sont examinés en détail (dossier de travail, chemin, arguments).
    public static func scan(projects: [URL], now: Date = Date(), minimumAge: TimeInterval = 5, cache: RecorderScanCache? = nil) -> [DetectedProcess] {
        guard !projects.isEmpty else { return [] }
        let me = getpid()
        let uid = getuid()
        struct Candidate { var pid: Int32; var ppid: Int32; var started: UInt64; var name: String; var path: String?; var project: URL }
        var all: [Int32: (ppid: Int32, started: UInt64)] = [:]
        var candidates: [Int32: Candidate] = [:]
        cache?.reset(ifProjectsChanged: projects)
        var rejected: [Int32: UInt64] = [:]
        // D'abord tout l'arbre (un parent peut avoir un PID plus grand que son enfant), puis l'examen.
        let infos = ProcessSampler.allPIDs().filter { $0 > 1 && $0 != me }.compactMap { pid in ProcessSampler.bsdInfo(pid).map { (pid, $0) } }
        for (pid, bsd) in infos { all[pid] = (bsd.ppid, bsd.started) }
        for (pid, bsd) in infos {
            if let cache, cache.rejected[pid] == bsd.started {
                rejected[pid] = bsd.started
                continue
            }
            func evaluate() -> Candidate? {
                guard bsd.uid == uid, let cwd = ProcessSampler.cwd(pid),
                      let project = ProjectMatcher.project(for: cwd, in: projects) else { return nil }
                var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
                let path = length > 0 ? String(nulTerminated: buffer) : nil
                let name = path.map { ($0 as NSString).lastPathComponent } ?? bsd.name
                guard !ignored.contains(name) else { return nil }
                let dev = ProcessRules.isDev(name: name, path: path)
                // Les apps graphiques ouvertes dans un dossier ne sont pas des processus du projet (sauf Python.app & co).
                if path?.contains(".app/Contents/") == true && !dev { return nil }
                guard dev || bsd.ppid == me || isDescendant(bsd.ppid, of: me, all: all) else { return nil }
                // Assistants d'éditeurs et d'outils (serveurs de langage, plugins) : pas du projet.
                if let args = ProcessTree.arguments(of: pid), args.dropFirst().prefix(2).contains(where: { arg in
                    helperDirectories.contains { arg.hasPrefix(NSHomeDirectory() + "/" + $0) } || arg.contains("/node_modules/typescript/lib/tsserver")
                }) { return nil }
                return Candidate(pid: pid, ppid: bsd.ppid, started: bsd.started, name: name, path: path, project: project)
            }
            if let candidate = evaluate() {
                candidates[pid] = candidate
            } else {
                rejected[pid] = bsd.started
            }
        }
        // Les processus terminés sortent du cache.
        cache?.rejected = rejected
        // Racines : processus dont le parent n'est pas lui-même un candidat du même projet.
        var result: [DetectedProcess] = []
        for candidate in candidates.values {
            if let parent = candidates[candidate.ppid], parent.project == candidate.project { continue }
            guard now.timeIntervalSince1970 - Double(candidate.started) >= minimumAge else { continue }
            let children = candidates.values.filter { isDescendant($0.pid, of: candidate.pid, all: all) }.count
            let args = ProcessTree.arguments(of: candidate.pid) ?? [candidate.name]
            result.append(DetectedProcess(
                pid: candidate.pid, started: candidate.started, project: candidate.project, name: candidate.name,
                command: displayCommand(args), children: children,
                fromAtelier: candidate.ppid == me || isDescendant(candidate.pid, of: me, all: all)
            ))
        }
        return result.sorted { $0.started < $1.started }
    }

    static func isDescendant(_ pid: Int32, of ancestor: Int32, all: [Int32: (ppid: Int32, started: UInt64)]) -> Bool {
        var current = pid
        var steps = 0
        while let parent = all[current]?.ppid, parent > 1, steps < 32 {
            if parent == ancestor { return true }
            current = parent
            steps += 1
        }
        return false
    }

    static func sensitiveFlag(_ flag: String) -> Bool {
        guard flag.hasPrefix("-") else { return false }
        return ["token", "password", "passwd", "secret", "key", "auth", "credential", "api-key", "apikey"].contains { flag.contains($0) }
    }

    /// Longue chaîne hexadécimale ou base64 sans séparateur : probablement une clé.
    static func looksLikeSecret(_ arg: String) -> Bool {
        guard arg.count >= 24, !arg.contains("/"), !arg.contains(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_+="))
        return arg.unicodeScalars.allSatisfy(allowed.contains) && arg.contains(where: \.isNumber) && arg.contains(where: \.isLetter)
    }

    /// « /opt/homebrew/bin/node /Users/…/node_modules/.bin/vite » → « node …/.bin/vite ».
    public static func displayCommand(_ args: [String]) -> String {
        var maskNext = false
        return args.prefix(6).enumerated().map { index, arg in
            if index == 0 { return (arg as NSString).lastPathComponent }
            // Jetons et mots de passe : jamais affichés ni enregistrés.
            if maskNext { maskNext = false; return "••••" }
            let lower = arg.lowercased()
            if let eq = arg.firstIndex(of: "="), sensitiveFlag(String(lower[..<eq])) { return String(arg[...eq]) + "••••" }
            if sensitiveFlag(lower) { maskNext = true; return arg }
            if looksLikeSecret(arg) { return "••••" }
            if arg.hasPrefix("/"), let range = arg.range(of: "node_modules/") { return "…/" + arg[range.upperBound...] }
            if arg.hasPrefix(NSHomeDirectory()) { return "~" + arg.dropFirst(NSHomeDirectory().count) }
            // Code passé en argument (python -c "…") : une ligne, abrégée.
            let flat = arg.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            return flat.count > 40 ? String(flat.prefix(39)) + "…" : flat
        }.joined(separator: " ") + (args.count > 6 ? " …" : "")
    }
}

// MARK: - Sessions

public struct RecordingSample: Sendable, Codable, Hashable {
    /// Secondes depuis le début.
    public var t: Double
    /// % (100 = un cœur plein).
    public var cpu: Double
    public var memory: Int64
    /// Octets par seconde.
    public var diskRead: Double
    public var diskWrite: Double
    public var processes: Int

    public init(t: Double, cpu: Double, memory: Int64, diskRead: Double, diskWrite: Double, processes: Int) {
        self.t = t
        self.cpu = cpu
        self.memory = memory
        self.diskRead = diskRead
        self.diskWrite = diskWrite
        self.processes = processes
    }
}

public struct RecordingMark: Sendable, Codable, Hashable {
    public var t: Double
    public var label: String
    public var auto: Bool

    public init(t: Double, label: String, auto: Bool) {
        self.t = t
        self.label = label
        self.auto = auto
    }
}

public struct RecordingSession: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var project: String
    public var command: String
    public var auto: Bool
    public var start: Date
    public var samples: [RecordingSample]
    public var marks: [RecordingMark]

    public init(id: UUID = UUID(), name: String, project: String, command: String, auto: Bool, start: Date,
                samples: [RecordingSample] = [], marks: [RecordingMark] = []) {
        self.id = id
        self.name = name
        self.project = project
        self.command = command
        self.auto = auto
        self.start = start
        self.samples = samples
        self.marks = marks
    }

    public var projectName: String { (project as NSString).lastPathComponent }
    public var duration: TimeInterval { samples.last?.t ?? 0 }
    public var averageCPU: Double { samples.isEmpty ? 0 : samples.reduce(0) { $0 + $1.cpu } / Double(samples.count) }
    public var maxCPU: Double { samples.map(\.cpu).max() ?? 0 }
    public var maxMemory: Int64 { samples.map(\.memory).max() ?? 0 }
    /// Octets lus / écrits sur la session (intégrale des débits).
    public var totalRead: Double { integrate(\.diskRead) }
    public var totalWritten: Double { integrate(\.diskWrite) }

    private func integrate(_ key: KeyPath<RecordingSample, Double>) -> Double {
        zip(samples, samples.dropFirst()).reduce(0) { sum, pair in sum + pair.1[keyPath: key] * (pair.1.t - pair.0.t) }
    }

    /// Écart relatif avec une session de référence (en %), pour CPU moyen, CPU max, mémoire max, durée.
    public func delta(from reference: RecordingSession) -> (cpu: Double?, maxCPU: Double?, memory: Double?, duration: Double?) {
        func pct(_ a: Double, _ b: Double) -> Double? { b > 0 ? (a - b) / b * 100 : nil }
        return (pct(averageCPU, reference.averageCPU), pct(maxCPU, reference.maxCPU),
                pct(Double(maxMemory), Double(reference.maxMemory)), pct(duration, reference.duration))
    }

    public func csv() -> String {
        var lines = ["t_s,cpu_pct,memoire_octets,lecture_octets_s,ecriture_octets_s,processus"]
        for s in samples {
            lines.append(String(format: "%.1f,%.1f,%lld,%.0f,%.0f,%d", s.t, s.cpu, s.memory, s.diskRead, s.diskWrite, s.processes))
        }
        if !marks.isEmpty {
            lines.append("")
            lines.append("repere_t_s,repere")
            for m in marks { lines.append(String(format: "%.1f,", m.t) + "\"\(m.label.replacingOccurrences(of: "\"", with: "\"\""))\"") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// Mesure d'un processus et de tous ses descendants.
public struct TreeSampler: Sendable {
    public let root: ProcessTarget
    private var previous: [Int32: (time: UInt64, read: UInt64, written: UInt64)] = [:]
    private var previousDate: Date?
    private let timebase: Double

    public init(root: ProcessTarget) {
        self.root = root
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = info.denom == 0 ? 1 : Double(info.numer) / Double(info.denom)
    }

    /// `nil` quand la racine s'est terminée.
    public mutating func sample(now: Date = Date()) -> (cpu: Double, memory: Int64, read: Double, write: Double, processes: Int)? {
        guard root.isAlive else { return nil }
        let pids = [root.pid] + ProcessTree.descendants(of: root.pid)
        let elapsed = previousDate.map { now.timeIntervalSince($0) } ?? 0
        var cpu = 0.0, read = 0.0, write = 0.0
        var memory: Int64 = 0
        var next: [Int32: (UInt64, UInt64, UInt64)] = [:]
        for pid in pids {
            guard let task = ProcessSampler.taskInfo(pid) else { continue }
            let time = UInt64(Double(task.time) * timebase)
            memory += task.footprint
            if let old = previous[pid], elapsed > 0.05 {
                cpu += Double(time &- old.time) / (elapsed * 1e9) * 100
                if task.diskRead >= old.read { read += Double(task.diskRead - old.read) / elapsed }
                if task.diskWritten >= old.written { write += Double(task.diskWritten - old.written) / elapsed }
            }
            next[pid] = (time, task.diskRead, task.diskWritten)
        }
        previous = next.mapValues { (time: $0.0, read: $0.1, written: $0.2) }
        previousDate = now
        return (max(0, cpu), memory, read, write, pids.count)
    }
}

/// Repères automatiques : pic de CPU, hausse brutale de mémoire.
public enum MarkDetector {
    public static func detect(samples: [RecordingSample], marks: [RecordingMark]) -> RecordingMark? {
        guard samples.count >= 10, let last = samples.last else { return nil }
        // Pas plus d'un repère automatique toutes les 15 s.
        if let lastAuto = marks.last(where: \.auto), last.t - lastAuto.t < 15 { return nil }
        let window = samples.dropLast().suffix(30)
        let average = window.reduce(0) { $0 + $1.cpu } / Double(window.count)
        if last.cpu >= 50, last.cpu >= average * 2 + 10 {
            return RecordingMark(t: last.t, label: "Pic CPU détecté (\(Int(last.cpu)) %)", auto: true)
        }
        if let before = samples.dropLast(5).last, before.memory > 50 << 20, Double(last.memory) >= Double(before.memory) * 1.3,
           last.memory - before.memory > 100 << 20 {
            return RecordingMark(t: last.t, label: "Hausse de mémoire (+\((last.memory - before.memory) >> 20) Mo)", auto: true)
        }
        return nil
    }
}

/// Sessions enregistrées : un fichier JSON par session dans Application Support.
public actor RecordingStore {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.latelier/recordings", isDirectory: true)
    }

    public func url(for session: RecordingSession) -> URL { directory.appendingPathComponent("\(session.id.uuidString).json") }

    public func all() -> [RecordingSession] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(RecordingSession.self, from: Data(contentsOf: $0)) }
            .sorted { $0.start > $1.start }
    }

    public func save(_ session: RecordingSession) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try session.json().write(to: url(for: session), options: .atomic)
    }
}
