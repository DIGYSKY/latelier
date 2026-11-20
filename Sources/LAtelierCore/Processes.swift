import AppKit
import Darwin
import Foundation

/// Un processus à un instant donné.
public struct RunningProcess: Sendable, Identifiable, Hashable {
    public var pid: Int32
    public var ppid: Int32
    public var uid: UInt32
    public var name: String
    /// Chemin de l'exécutable, quand il est lisible.
    public var path: String?
    /// Début du processus (secondes depuis 1970) : avec le PID, identifie le processus sans ambiguïté.
    public var started: UInt64
    /// 0…100 par cœur (comme le Moniteur d'activité : 200 % = deux cœurs pleins).
    public var cpu: Double
    /// Empreinte mémoire (octets).
    public var memory: Int64
    public var threads: Int?
    /// Réveils par seconde, pour estimer l'impact énergétique.
    public var wakeups: Double
    /// Dossier de travail (processus de l'utilisateur seulement).
    public var cwd: String?
    /// Lu avec les droits de l'utilisateur (sinon via `ps`, sans threads ni dossier).
    public var detailed: Bool

    public var id: Int32 { pid }

    public var isMine: Bool { uid == getuid() }

    /// Paquet `.app` le plus extérieur (Chrome et ses « Helper » sont regroupés).
    public var appBundle: String? {
        guard let path, let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// Processus du système : fourni par macOS, ou lancé par un autre compte.
    public var isSystem: Bool {
        if !isMine { return true }
        guard let path else { return ProcessRules.protectedNames.contains(name) }
        return ProcessRules.systemPrefixes.contains { path.hasPrefix($0) } || ProcessRules.protectedNames.contains(name)
    }

    /// On peut le quitter d'ici : à l'utilisateur, pas système, pas L’Atelier lui-même.
    public var canQuit: Bool { !isSystem && pid != getpid() && pid > 1 }

    public var energy: EnergyImpact { EnergyImpact(cpu: cpu, wakeups: wakeups) }

    public var isDev: Bool { ProcessRules.isDev(name: name, path: path) }

    public var target: ProcessTarget { ProcessTarget(pid: pid, name: name, started: started, isApp: appBundle != nil && path?.contains(".app/Contents/MacOS/") == true) }
}

/// Estimation grossière de l'impact énergétique (le calcul d'Apple n'est pas public).
public enum EnergyImpact: Int, Sendable, Comparable {
    case none, low, medium, high

    init(cpu: Double, wakeups: Double) {
        let score = cpu + wakeups / 50
        self = score >= 30 ? .high : score >= 5 ? .medium : score >= 0.3 ? .low : .none
    }

    public var label: String {
        switch self {
        case .none: "—"
        case .low: "Faible"
        case .medium: "Moyenne"
        case .high: "Élevée"
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum ProcessRules {
    static let systemPrefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/private/var/", "/Applications/Utilities/"]
    /// Processus dont la fin ferme la session ou casse l'interface.
    static let protectedNames: Set<String> = [
        "launchd", "kernel_task", "loginwindow", "WindowServer", "Dock", "SystemUIServer", "Finder",
        "ControlCenter", "NotificationCenter", "coreaudiod", "cfprefsd", "distnoted", "UserEventAgent",
    ]
    static let devNames: Set<String> = [
        "node", "nodejs", "deno", "bun", "java", "ruby", "go", "gopls", "cargo", "rustc", "rust-analyzer",
        "php", "php-fpm", "postgres", "postmaster", "redis-server", "mysqld", "mariadbd", "mongod", "nginx", "httpd",
        "ollama", "docker", "dockerd", "containerd", "vite", "esbuild", "tsserver", "npm", "npx", "yarn", "pnpm",
        "uv", "poetry", "pip", "bundle", "rails", "puma", "uvicorn", "gunicorn", "beam.smp", "dotnet", "kubectl",
        "minikube", "colima", "limactl", "qemu-system-aarch64", "swift-frontend", "sourcekit-lsp", "xcodebuild",
        "clangd", "make", "cmake", "ninja", "gradle", "mvn", "jupyter", "jupyter-lab", "caddy", "memcached",
        "elasticsearch", "rabbitmq-server", "turbo", "next-server", "webpack", "watchman", "esbuild-darwin-arm64",
    ]

    static func isDev(name: String, path: String?) -> Bool {
        let lower = name.lowercased()
        if devNames.contains(lower) || lower.hasPrefix("python") || lower.hasPrefix("com.docker.") || lower.hasPrefix("node-") {
            return true
        }
        guard let path else { return false }
        return path.contains("/Docker.app/") || path.contains("/.cargo/bin/") || path.contains("/node_modules/")
            || path.contains("/.nvm/") || path.contains("/.pyenv/") || path.contains("/.rbenv/") || path.contains("/.rustup/")
    }
}

/// Ce qu'il faut pour viser un processus sans risque de confusion (PID réutilisé).
public struct ProcessTarget: Sendable, Hashable {
    public var pid: Int32
    public var name: String
    public var started: UInt64
    /// App avec interface : « Quitter » passe par l'app (elle peut proposer d'enregistrer).
    public var isApp: Bool

    public init(pid: Int32, name: String, started: UInt64, isApp: Bool = false) {
        self.pid = pid
        self.name = name
        self.started = started
        self.isApp = isApp
    }

    /// Cible pour un PID en cours (avec son heure de départ, pour ne pas viser un PID réutilisé).
    public static func current(pid: Int32, name: String, isApp: Bool) -> ProcessTarget? {
        guard let info = ProcessSampler.bsdInfo(pid) else { return nil }
        return ProcessTarget(pid: pid, name: name, started: info.started, isApp: isApp)
    }

    /// Le même processus tourne-t-il toujours ?
    public var isAlive: Bool {
        guard let info = ProcessSampler.bsdInfo(pid) else { return false }
        return started == 0 || info.started == started
    }
}

// MARK: - Échantillonnage

/// Liste des processus avec CPU instantané. Les processus de l'utilisateur sont lus avec
/// libproc ; ceux du système (refusés sans droits admin) avec `ps`, rafraîchis moins souvent.
public struct ProcessSampler: Sendable {
    private var previous: [Int32: (time: UInt64, wakeups: UInt64, started: UInt64)] = [:]
    private var previousDate: Date?
    private var foreign: [Int32: RunningProcess] = [:]
    private var foreignDate: Date?
    private let timebase: Double
    public let runner: CommandRunner

    public init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = info.denom == 0 ? 1 : Double(info.numer) / Double(info.denom)
    }

    public mutating func sample(now: Date = Date()) async -> [RunningProcess] {
        if foreignDate == nil || now.timeIntervalSince(foreignDate!) >= 3 {
            foreign = await Self.psSnapshot(runner: runner)
            foreignDate = now
        }
        let elapsed = previousDate.map { now.timeIntervalSince($0) } ?? 0
        var next: [Int32: (UInt64, UInt64, UInt64)] = [:]
        var result: [RunningProcess] = []
        for pid in Self.allPIDs() where pid > 0 {
            guard let bsd = Self.bsdInfo(pid), var task = Self.taskInfo(pid) else {
                if let other = foreign[pid] { result.append(other) }
                continue
            }
            let time = UInt64(Double(task.time) * timebase)
            var cpu = 0.0
            var wakeups = 0.0
            if let old = previous[pid], old.started == bsd.started, elapsed > 0.05 {
                cpu = Double(time &- old.time) / (elapsed * 1e9) * 100
                wakeups = Double(task.wakeups &- old.wakeups) / elapsed
            }
            next[pid] = (time, task.wakeups, bsd.started)
            task.path = task.path ?? foreign[pid]?.path
            result.append(RunningProcess(
                pid: pid, ppid: bsd.ppid, uid: bsd.uid, name: task.path.map { ($0 as NSString).lastPathComponent } ?? bsd.name,
                path: task.path, started: bsd.started, cpu: max(0, cpu), memory: task.footprint, threads: task.threads,
                wakeups: max(0, wakeups), cwd: bsd.uid == getuid() ? Self.cwd(pid) : nil, detailed: true
            ))
        }
        // kernel_task (PID 0) n'apparaît que via ps.
        if let kernel = foreign[0] { result.append(kernel) }
        previous = next.mapValues { (time: $0.0, wakeups: $0.1, started: $0.2) }
        previousDate = now
        return result
    }

    static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return Array(pids.prefix(Int(max(0, filled))))
    }

    struct BSD { var ppid: Int32; var uid: UInt32; var name: String; var started: UInt64 }

    static func bsdInfo(_ pid: Int32) -> BSD? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: info.pbi_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let comm = withUnsafeBytes(of: info.pbi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return BSD(ppid: Int32(info.pbi_ppid), uid: info.pbi_uid, name: name.isEmpty ? comm : name, started: info.pbi_start_tvsec)
    }

    struct Task { var time: UInt64; var footprint: Int64; var threads: Int; var wakeups: UInt64; var path: String?; var diskRead: UInt64 = 0; var diskWritten: UInt64 = 0 }

    static func taskInfo(_ pid: Int32) -> Task? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        } == 0
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return Task(
            time: info.pti_total_user &+ info.pti_total_system,
            footprint: ok ? Int64(usage.ri_phys_footprint) : Int64(info.pti_resident_size),
            threads: Int(info.pti_threadnum),
            wakeups: ok ? usage.ri_pkg_idle_wkups &+ usage.ri_interrupt_wkups : 0,
            path: length > 0 ? String(nulTerminated: buffer) : nil,
            diskRead: ok ? usage.ri_diskio_bytesread : 0,
            diskWritten: ok ? usage.ri_diskio_byteswritten : 0
        )
    }

    static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty || path == "/" ? nil : path
    }

    /// `ps` est setuid : il voit aussi les processus du système.
    static func psSnapshot(runner: CommandRunner) async -> [Int32: RunningProcess] {
        let spec = CommandSpec("/bin/ps", ["-axww", "-o", "pid=,ppid=,uid=,pcpu=,rss=,lstart=,comm="])
        guard let result = try? await runner.run(spec, timeout: .seconds(5)) else { return [:] }
        return parsePS(result.stdout)
    }

    private static let lstartFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()

    /// `  221     1    88   4,0  61232 Tue Nov 18 09:12:01 2026     /System/…/WindowServer`
    static func parsePS(_ lines: [String]) -> [Int32: RunningProcess] {
        var result: [Int32: RunningProcess] = [:]
        for line in lines {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 11, let pid = Int32(fields[0]), let ppid = Int32(fields[1]), let uid = UInt32(fields[2]) else { continue }
            let cpu = Double(fields[3].replacingOccurrences(of: ",", with: ".")) ?? 0
            let rss = (Int64(fields[4]) ?? 0) * 1024
            let started = lstartFormatter.date(from: fields[5...9].joined(separator: " "))
            // La commande peut contenir des espaces : on reprend la fin de la ligne.
            let commandStart = line.range(of: String(fields[9]))!.upperBound
            let command = line[commandStart...].trimmingCharacters(in: .whitespaces)
            let path = command.hasPrefix("/") ? command : nil
            result[pid] = RunningProcess(
                pid: pid, ppid: ppid, uid: uid, name: (command as NSString).lastPathComponent, path: path,
                started: started.map { UInt64($0.timeIntervalSince1970) } ?? 0, cpu: cpu, memory: rss, threads: nil,
                wakeups: 0, cwd: nil, detailed: false
            )
        }
        return result
    }
}

// MARK: - Regroupement par app

/// Une app et ses processus d'aide, ou tous les processus d'un même exécutable.
public struct ProcessGroup: Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Paquet `.app`, pour l'icône.
    public var bundle: String?
    public var processes: [RunningProcess]
    /// Projet dont viennent les processus, s'il y en a un.
    public var project: URL?

    public var cpu: Double { processes.reduce(0) { $0 + $1.cpu } }
    public var memory: Int64 { processes.reduce(0) { $0 + $1.memory } }
    public var threads: Int? {
        let known = processes.compactMap(\.threads)
        return known.isEmpty ? nil : known.reduce(0, +)
    }
    public var energy: EnergyImpact { processes.map(\.energy).max() ?? .none }
    public var isSystem: Bool { processes.allSatisfy { $0.isSystem } }
    public var isMine: Bool { processes.contains { $0.isMine } }
    public var isDev: Bool { project != nil || processes.contains { $0.isDev } }

    /// Processus à quitter pour fermer le groupe : l'app principale, sinon tous.
    public var quitTargets: [ProcessTarget] {
        let quittable = processes.filter(\.canQuit)
        if bundle != nil, let main = quittable.first(where: { p in !quittable.contains { $0.pid == p.ppid } && p.target.isApp }) {
            return [main.target]
        }
        return quittable.map(\.target)
    }

    public static func group(_ processes: [RunningProcess], projects: [URL] = []) -> [ProcessGroup] {
        var groups: [String: ProcessGroup] = [:]
        for process in processes {
            let key: String
            let name: String
            if let bundle = process.appBundle {
                key = bundle
                name = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
            } else {
                // Les processus d'un même outil sont regroupés, mais pas ceux de comptes différents.
                key = "\(process.name)#\(process.isMine)"
                name = process.name
            }
            var group = groups[key] ?? ProcessGroup(id: key, name: name, bundle: process.appBundle, processes: [], project: nil)
            group.processes.append(process)
            if group.project == nil, let cwd = process.cwd { group.project = ProjectMatcher.project(for: cwd, in: projects) }
            groups[key] = group
        }
        return Array(groups.values)
    }
}

public enum ProjectMatcher {
    /// Le projet le plus profond qui contient le chemin.
    public static func project(for path: String, in projects: [URL]) -> URL? {
        projects
            .filter { path == $0.path || path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }
}

// MARK: - Ports et connexions

public struct ListeningPort: Sendable, Identifiable, Hashable {
    public var port: Int
    public var pid: Int32
    public var command: String
    public var addresses: [String]

    public var id: String { "\(pid):\(port)" }

    /// Joignable depuis le réseau local (`*`, `0.0.0.0`, `::` ou une adresse non locale).
    public var exposed: Bool { addresses.contains { !Self.isLoopback($0) } }

    static func isLoopback(_ address: String) -> Bool {
        address.hasPrefix("127.") || address == "[::1]" || address == "::1" || address == "localhost"
    }

    public var displayAddress: String {
        if addresses.contains("*") { return "0.0.0.0" }
        return addresses.sorted { $0.count < $1.count }.first ?? "?"
    }
}

/// Connexions établies d'un processus.
public struct ProcessConnections: Sendable, Equatable {
    public var count: Int
    public var hosts: [String]
}

public struct PortScanner: Sendable {
    public let runner: CommandRunner

    public init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
    }

    /// Sans droits admin, `lsof` ne voit que les sockets de l'utilisateur.
    public func listening() async -> [ListeningPort] {
        let spec = CommandSpec("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn", "-w"])
        guard let result = try? await runner.run(spec, timeout: .seconds(8)) else { return [] }
        return Self.parseListening(result.stdout)
    }

    public func connections() async -> [Int32: ProcessConnections] {
        let spec = CommandSpec("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:ESTABLISHED", "-F", "pn", "-w"])
        guard let result = try? await runner.run(spec, timeout: .seconds(8)) else { return [:] }
        return Self.parseConnections(result.stdout)
    }

    static func parseListening(_ lines: [String]) -> [ListeningPort] {
        var pid: Int32 = 0
        var command = ""
        var ports: [String: ListeningPort] = [:]
        for line in lines {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let address = String(value[..<colon])
                let key = "\(pid):\(port)"
                var entry = ports[key] ?? ListeningPort(port: port, pid: pid, command: command, addresses: [])
                if !entry.addresses.contains(address) { entry.addresses.append(address) }
                ports[key] = entry
            default: break
            }
        }
        return ports.values.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// `n192.168.1.20:52144->140.82.112.3:443`
    static func parseConnections(_ lines: [String]) -> [Int32: ProcessConnections] {
        var pid: Int32 = 0
        var result: [Int32: ProcessConnections] = [:]
        for line in lines {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            if tag == "p" { pid = Int32(value) ?? 0; continue }
            guard tag == "n", let arrow = value.range(of: "->") else { continue }
            let remote = String(value[arrow.upperBound...])
            let host = remote.lastIndex(of: ":").map { String(remote[..<$0]) } ?? remote
            var entry = result[pid] ?? ProcessConnections(count: 0, hosts: [])
            entry.count += 1
            if !entry.hosts.contains(host), !ListeningPort.isLoopback(host) { entry.hosts.append(host) }
            result[pid] = entry
        }
        return result
    }
}

// MARK: - Trafic par processus

/// Octets échangés par processus, depuis son démarrage (`nettop`, sans droits admin).
public struct TrafficSampler: Sendable {
    public let runner: CommandRunner
    private var previous: [Int32: (Date, UInt64, UInt64)] = [:]

    public init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
    }

    public struct Rate: Sendable, Equatable {
        public var name: String
        public var down: Double
        public var up: Double
        public var totalDown: UInt64
        public var totalUp: UInt64
    }

    /// Prend environ 5 s (`nettop` attend un intervalle complet).
    public mutating func sample() async -> [Int32: Rate] {
        let spec = CommandSpec("/usr/bin/nettop", ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"])
        guard let result = try? await runner.run(spec, timeout: .seconds(15)) else { return [:] }
        let now = Date()
        var rates: [Int32: Rate] = [:]
        var next: [Int32: (Date, UInt64, UInt64)] = [:]
        for (pid, entry) in Self.parse(result.stdout) {
            var rate = Rate(name: entry.name, down: 0, up: 0, totalDown: entry.down, totalUp: entry.up)
            if let (date, down, up) = previous[pid], entry.down >= down, entry.up >= up {
                let elapsed = max(0.5, now.timeIntervalSince(date))
                rate.down = Double(entry.down - down) / elapsed
                rate.up = Double(entry.up - up) / elapsed
            }
            rates[pid] = rate
            next[pid] = (now, entry.down, entry.up)
        }
        previous = next
        return rates
    }

    /// `Google Chrome H.5133,123,456,` (le nom peut contenir des points : le PID est après le dernier).
    static func parse(_ lines: [String]) -> [Int32: (name: String, down: UInt64, up: UInt64)] {
        var result: [Int32: (name: String, down: UInt64, up: UInt64)] = [:]
        for line in lines {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let dot = fields[0].lastIndex(of: "."),
                  let pid = Int32(fields[0][fields[0].index(after: dot)...]),
                  let down = UInt64(fields[1]), let up = UInt64(fields[2]) else { continue }
            result[pid] = (String(fields[0][..<dot]), down, up)
        }
        return result
    }
}

// MARK: - Actions

public enum ProcessActions {
    /// Quitter (ou forcer à quitter) des processus, après aperçu.
    public static func quitPlan(_ targets: [ProcessTarget], label: String, force: Bool, reason: String? = nil) -> ActionPlan? {
        guard !targets.isEmpty else { return nil }
        let count = targets.count
        let what = count == 1 ? "le processus" : "les \(count) processus"
        var summary = force
            ? "Arrête immédiatement \(what) de \(label). Le travail non enregistré sera perdu."
            : "Demande à \(label) de se fermer. Une app peut proposer d’enregistrer avant de quitter."
        if let reason { summary += " " + reason }
        return ActionPlan(
            title: force ? "Forcer \(label) à quitter" : "Quitter \(label)",
            summary: summary,
            kind: .processus, risk: force ? .danger : .caution, reversible: false,
            steps: targets.map { .signal($0, force: force) }, stopOnFailure: false
        )
    }
}

/// Quitte un processus en vérifiant d'abord que c'est bien le même (le PID a pu être réutilisé).
public enum ProcessTerminator {
    public enum Failure: Error, LocalizedError {
        case gone(String)
        case refused(String, String)
        case stillRunning(String)

        public var errorDescription: String? {
            switch self {
            case .gone(let name): "« \(name) » ne tourne plus (rien à faire)."
            case .refused(let name, let reason): "Impossible de quitter « \(name) » : \(reason)."
            case .stillRunning(let name): "« \(name) » tourne toujours : il attend peut-être une réponse dans une fenêtre, ou ignore la demande. « Forcer à quitter » l’arrête sans attendre."
            }
        }
    }

    public static func terminate(_ target: ProcessTarget, force: Bool) async throws -> String {
        guard target.isAlive else { throw Failure.gone(target.name) }
        guard target.pid > 1, target.pid != getpid() else { throw Failure.refused(target.name, "processus protégé") }
        var askedApp = false
        if target.isApp && !force {
            askedApp = await MainActor.run {
                NSRunningApplication(processIdentifier: target.pid)?.terminate() ?? false
            }
        }
        if !askedApp {
            guard kill(target.pid, force ? SIGKILL : SIGTERM) == 0 else {
                throw Failure.refused(target.name, String(cString: strerror(errno)))
            }
        }
        // Une app peut demander d'enregistrer : on lui laisse quelques secondes.
        let deadline = Date().addingTimeInterval(force ? 2 : 6)
        while Date() < deadline {
            if !target.isAlive { return "\(target.name) (PID \(target.pid)) a quitté." }
            try? await Task.sleep(for: .milliseconds(150))
        }
        throw Failure.stillRunning(target.name)
    }
}

public enum ProcessTree {
    /// Descendants d'un processus (en largeur : enfants, puis petits-enfants…).
    public static func descendants(of root: Int32) -> [Int32] {
        var children: [Int32: [Int32]] = [:]
        for pid in ProcessSampler.allPIDs() {
            if let info = ProcessSampler.bsdInfo(pid) { children[info.ppid, default: []].append(pid) }
        }
        var result: [Int32] = []
        var queue = children[root] ?? []
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            guard pid != root, !result.contains(pid) else { continue }
            result.append(pid)
            queue += children[pid] ?? []
        }
        return result
    }

    /// Ligne de commande complète (`KERN_PROCARGS2`), processus de l'utilisateur seulement.
    public static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Chemin de l'exécutable, puis des zéros de remplissage.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        var start = index
        while index < size, args.count < Int(argc) {
            if buffer[index] == 0 {
                args.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return args
    }
}
