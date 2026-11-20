import Foundation

/// Un service géré par `brew services` (postgres, redis, nginx…).
public struct BrewService: Sendable, Hashable, Identifiable {
    public var name: String
    public var running: Bool
    /// Inscrit au démarrage de session (`brew services start`), par opposition à `brew services run`.
    public var registered: Bool
    public var pid: Int32?
    public var exitCode: Int?
    /// Lancé avec sudo : on ne le pilote pas d'ici.
    public var user: String?
    public var logPath: String?
    public var errorLogPath: String?
    public var ports: [Int] = []
    public var memory: Int64?
    public var summary: String = ""

    public var id: String { name }
    public var runsAsRoot: Bool { user == "root" }
    /// Arrêté avec un code d'erreur.
    public var failed: Bool { !running && (exitCode ?? 0) != 0 }

    public init(name: String, running: Bool, registered: Bool, pid: Int32? = nil, exitCode: Int? = nil,
                user: String? = nil, logPath: String? = nil, errorLogPath: String? = nil) {
        self.name = name
        self.running = running
        self.registered = registered
        self.pid = pid
        self.exitCode = exitCode
        self.user = user
        self.logPath = logPath
        self.errorLogPath = errorLogPath
    }
}

public enum BrewServices {
    /// `brew services info --all --json`
    public static func parse(_ data: Data) -> [BrewService] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return BrewService(
                name: name,
                running: row["running"] as? Bool ?? false,
                registered: row["registered"] as? Bool ?? false,
                pid: (row["pid"] as? NSNumber)?.int32Value,
                exitCode: (row["exit_code"] as? NSNumber)?.intValue,
                user: row["user"] as? String,
                logPath: row["log_path"] as? String,
                errorLogPath: row["error_log_path"] as? String
            )
        }
    }

    /// `lsof -F n` : lignes `p<pid>` puis `n*:5432` ou `n127.0.0.1:6379`.
    public static func parsePorts(_ lines: [String]) -> [Int32: [Int]] {
        var result: [Int32: Set<Int>] = [:]
        var pid: Int32?
        for line in lines {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) }
            if line.hasPrefix("n"), let pid, let colon = line.lastIndex(of: ":"), let port = Int(line[line.index(after: colon)...]) {
                result[pid, default: []].insert(port)
            }
        }
        return result.mapValues { $0.sorted() }
    }

    public enum Action: String, Sendable {
        case start, stop, restart, run

        public var label: String {
            switch self {
            case .start: String(localized: "Démarrer")
            case .stop: String(localized: "Arrêter")
            case .restart: String(localized: "Redémarrer")
            case .run: String(localized: "Lancer sans inscrire au démarrage")
            }
        }
    }

    public static func command(_ action: Action, _ name: String) -> CommandSpec {
        CommandSpec("brew", ["services", action.rawValue, name], environment: Brew.environment)
    }

    /// Passe un service en cours entre « au démarrage » et « cette session seulement ».
    public static func toggleAtLogin(_ service: BrewService) -> ActionPlan {
        let steps: [CommandSpec] = service.registered
            ? [command(.stop, service.name), command(.run, service.name)]
            : [command(.start, service.name)]
        return ActionPlan(
            title: service.registered ? String(localized: "Ne plus lancer \(service.name) au démarrage") : String(localized: "Lancer \(service.name) au démarrage"),
            summary: service.registered ? String(localized: "Le service est relancé tout de suite, sans être inscrit au démarrage.") : String(localized: "Le service sera relancé à chaque ouverture de session."),
            kind: .systeme, risk: .safe, reversible: true, commands: steps
        )
    }

    public static func stopAll(_ services: [BrewService]) -> ActionPlan? {
        let targets = services.filter { $0.running && !$0.runsAsRoot }
        guard !targets.isEmpty else { return nil }
        var plan = ActionPlan(
            title: String(localized: "Arrêter \(targets.count) service(s)"),
            summary: String(localized: "Les services inscrits au démarrage ne seront plus relancés à l’ouverture de session. Les connexions en cours sont coupées."),
            kind: .systeme, risk: .caution, reversible: true,
            commands: targets.map { command(.stop, $0.name) }
        )
        plan.stopOnFailure = false
        plan.skipped = services.filter { $0.running && $0.runsAsRoot }.map { String(localized: "\($0.name) : lancé en root (sudo)") }
        return plan
    }

    /// Dernières lignes des logs du service.
    public static func logTail(_ service: BrewService, lines: Int = 40) -> String {
        let paths = [service.logPath, service.errorLogPath].compactMap { $0 }
        var seen = Set<String>()
        var chunks: [String] = []
        for path in paths where seen.insert(path).inserted {
            guard let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
            let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
            let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
            if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append(paths.count > 1 && seen.count > 1 ? "— \(URL(fileURLWithPath: path).lastPathComponent)\n\(tail)" : tail)
            }
        }
        return chunks.isEmpty ? String(localized: "(aucun log)") : chunks.joined(separator: "\n\n")
    }
}

public struct ServiceScanner: Sendable {
    public let runner: CommandRunner

    public init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
    }

    public func scan() async -> (services: [BrewService], problem: String?) {
        guard runner.locator.locate("brew") != nil else { return ([], nil) }
        guard let result = try? await runner.run(
            CommandSpec("brew", ["services", "info", "--all", "--json"], environment: Brew.environment), timeout: .seconds(30)
        ), result.succeeded else {
            return ([], String(localized: "brew services n’a pas répondu."))
        }
        var services = BrewServices.parse(Data(result.stdout.joined(separator: "\n").utf8))
        let pids = services.compactMap(\.pid)
        if !pids.isEmpty {
            let list = pids.map(String.init).joined(separator: ",")
            async let lsof = try? runner.run(
                CommandSpec("/usr/sbin/lsof", ["-nP", "-a", "-p", list, "-iTCP", "-sTCP:LISTEN", "-F", "pn"]), timeout: .seconds(8)
            )
            async let ps = try? runner.run(CommandSpec("/bin/ps", ["-o", "pid=,rss=", "-p", list]), timeout: .seconds(5))
            let ports = BrewServices.parsePorts(await lsof?.stdout ?? [])
            var memory: [Int32: Int64] = [:]
            for line in await ps?.stdout ?? [] {
                let parts = line.split(separator: " ")
                if parts.count == 2, let pid = Int32(parts[0]), let kb = Int64(parts[1]) { memory[pid] = kb * 1024 }
            }
            services = services.map { service in
                var service = service
                if let pid = service.pid {
                    service.ports = ports[pid] ?? []
                    service.memory = memory[pid]
                }
                return service
            }
        }
        return (services, nil)
    }
}
