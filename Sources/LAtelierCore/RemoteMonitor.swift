import Foundation

// MARK: - Données

/// Une mesure du serveur (toutes les ~2 s). Débits et pourcentages calculés par différence avec la précédente.
public struct RemoteSample: Sendable, Equatable {
    public var time: Date
    /// 0…100
    public var cpu: Double
    public var cores: [Double]
    public var iowait: Double
    public var load: [Double]
    public var memoryTotal: Int64
    public var memoryUsed: Int64
    public var memoryCached: Int64
    public var swapTotal: Int64
    public var swapUsed: Int64
    /// Octets par seconde.
    public var networkIn: Double
    public var networkOut: Double
    public var diskRead: Double
    public var diskWrite: Double
}

public struct RemoteProcess: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var ppid: Int32
    public var user: String
    public var cpu: Double
    public var memoryPercent: Double
    public var resident: Int64
    /// Secondes depuis le lancement.
    public var elapsed: Int
    public var state: String
    public var command: String
    /// Date de lancement (horloge du serveur), pour vérifier avant d'arrêter que le PID n'a pas changé de processus.
    public var started: Int

    public var id: Int32 { pid }

    /// `nginx: worker process` → `nginx` ; `/usr/bin/python3 app.py` → `python3`.
    public var name: String {
        let first = command.split(separator: " ").first.map(String.init) ?? command
        let base = (first as NSString).lastPathComponent
        return base.hasSuffix(":") ? String(base.dropLast()) : base
    }

    public var isKernelThread: Bool { command.hasPrefix("[") && command.hasSuffix("]") }
}

public struct RemoteDisk: Sendable, Equatable, Identifiable {
    public var device: String
    public var type: String
    public var size: Int64
    public var used: Int64
    public var available: Int64
    public var mount: String

    public var id: String { mount }
    public var fraction: Double { size > 0 ? Double(used) / Double(size) : 0 }
}

public struct RemotePort: Sendable, Equatable, Identifiable {
    public var proto: String
    public var address: String
    public var port: Int
    public var process: String?
    public var pid: Int32?

    public var id: String { "\(proto)-\(address)-\(port)" }
    /// Écoute sur toutes les interfaces (joignable depuis le réseau, selon le pare-feu).
    public var exposed: Bool { !["127.0.0.1", "::1", "localhost"].contains(address) && !address.hasPrefix("127.") }
}

public struct RemoteService: Sendable, Equatable, Identifiable {
    public var name: String
    public var active: String
    public var sub: String
    public var description: String

    public var id: String { name }
    public var failed: Bool { active == "failed" || sub == "failed" }
    public var running: Bool { sub == "running" }
}

public struct RemoteContainer: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var image: String
    public var state: String
    public var status: String
    public var cpu: Double?
    public var memory: String?
    public var memoryPercent: Double?

    public var running: Bool { state == "running" }
}

public struct RemoteSystemInfo: Sendable, Equatable {
    public var hostname: String = ""
    public var os: String = ""
    public var kernel: String = ""
    public var uptime: TimeInterval = 0
    public var users: Int = 0
    public var login: String = ""
    public var isRoot = false
    /// `sudo -n` fonctionne (root, ou sudo sans mot de passe) : les actions privilégiées passent par l'aperçu.
    public var canSudo = false
}

/// Disponibilité d'un outil sur le serveur.
public enum RemoteAvailability: Sendable, Equatable {
    case available, absent, denied
}

/// Ce qu'une mesure apporte. Les sections lentes (disques, ports, services, Docker) n'arrivent
/// qu'une fois sur cinq : `nil` = pas dans cette mesure, garder la précédente.
public struct RemoteSnapshot: Sendable {
    public var sample: RemoteSample?
    public var processes: [RemoteProcess] = []
    public var info: RemoteSystemInfo?
    public var disks: [RemoteDisk]?
    public var ports: [RemotePort]?
    public var portsAvailability: RemoteAvailability?
    public var services: [RemoteService]?
    public var servicesAvailability: RemoteAvailability?
    public var containers: [RemoteContainer]?
    public var dockerAvailability: RemoteAvailability?
}

// MARK: - Script et lecture

/// Moniteur sans agent : une boucle `sh` sur le serveur, qui lit /proc et quelques commandes
/// standard, et envoie une mesure toutes les 2 s tant que la connexion est ouverte.
public enum RemoteMonitorScript {
    /// Seul `sudo -n true` du tout premier passage teste les droits (une seule ligne dans les journaux du serveur).
    public static let script = #"""
    LC_ALL=C; export LC_ALL
    T="${TMPDIR:-/tmp}/.latelier-monitor.$$"
    trap 'rm -f "$T" "$T.n"' EXIT
    trap 'exit 0' INT TERM HUP PIPE
    i=0
    while :; do
      echo "@@T $(date +%s)"
      if [ $((i % 30)) -eq 0 ]; then
        echo "@@INFO"
        (hostname 2>/dev/null || cat /etc/hostname)
        (. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")
        uname -r
        cut -d' ' -f1 /proc/uptime
        who 2>/dev/null | wc -l
        id -un
        id -u
        getconf CLK_TCK 2>/dev/null || echo 100
        if [ $i -eq 0 ]; then
          if [ "$(id -u)" = 0 ] || sudo -n true 2>/dev/null; then echo sudo; else echo nosudo; fi
        fi
      fi
      echo "@@STAT"; grep '^cpu' /proc/stat
      echo "@@LOAD"; cat /proc/loadavg
      echo "@@MEM"; grep -E '^(MemTotal|MemAvailable|MemFree|Buffers|Cached|SReclaimable|SwapTotal|SwapFree):' /proc/meminfo
      echo "@@NET"; tail -n +3 /proc/net/dev
      echo "@@IO"; cat /proc/diskstats
      # CPU instantané : temps processeur (ticks) de chaque processus, comparé au passage précédent.
      C=$(awk -v prev="$T" -v out="$T.n" 'BEGIN { while ((getline l < prev) > 0) { split(l, a, " "); p[a[1]] = a[2] } }
        { i = index($0, ") "); if (!i) next; split(substr($0, i + 2), f, " "); t = f[12] + f[13]; print $1 " " t > out
          if ($1 in p) { d = t - p[$1]; if (d > 0) print $1 " " d } }' /proc/[0-9]*/stat 2>/dev/null | sort -k2 -rn | head -n 50)
      mv -f "$T.n" "$T" 2>/dev/null
      echo "@@CPU"; [ -n "$C" ] && echo "$C"
      M=$(ps -eo pid= --sort=-rss 2>/dev/null | head -n 40)
      P=$(printf '%s\n%s\n' "$C" "$M" | awk 'NF { print $1 }' | sort -un | tr '\n' ',' | sed 's/,$//')
      echo "@@PS"; [ -n "$P" ] && ps -o pid=,ppid=,user:24=,pcpu=,pmem=,rss=,etimes=,stat=,args= -p "$P" 2>/dev/null
      if [ $((i % 5)) -eq 0 ]; then
        echo "@@DF"; df -PkT -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | tail -n +2
        echo "@@PORTS"
        if command -v ss >/dev/null 2>&1; then ss -Htlnp 2>/dev/null; else echo '!absent'; fi
        echo "@@SERVICES"
        if command -v systemctl >/dev/null 2>&1; then
          systemctl list-units --type=service --all --no-legend --no-pager --plain 2>/dev/null | grep -E ' (running|failed) '
        else echo '!absent'; fi
        echo "@@DOCKER"
        if command -v docker >/dev/null 2>&1; then
          docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}' 2>/dev/null || echo '!denied'
          echo "@@DSTATS"
          timeout 5 docker stats --no-stream --format '{{.ID}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' 2>/dev/null
        else echo '!absent'; fi
      fi
      echo "@@END"
      i=$((i + 1))
      sleep 2
    done
    """#

    /// Commande distante : le script passe par `sh`, quel que soit le shell de connexion.
    public static var remoteCommand: String { "exec sh -c " + ShellQuote.quote(script) }
}

/// Lit le flux du script ligne par ligne et rend une mesure complète à chaque `@@END`.
public struct RemoteMonitorParser: Sendable {
    private var sections: [String: [String]] = [:]
    private var current: String?
    private var time: Int?
    private var previous: Counters?
    /// Ticks par seconde du noyau (CLK_TCK), pour le CPU des processus.
    private var hz: Double = 100

    struct Counters: Sendable {
        var time: Int
        var cpu: [[Int64]]
        var netIn: Int64
        var netOut: Int64
        var readSectors: Int64
        var writeSectors: Int64
    }

    public init() {}

    public mutating func feed(_ line: String) -> RemoteSnapshot? {
        if line.hasPrefix("@@T ") {
            sections = [:]
            current = nil
            time = Int(line.dropFirst(4).trimmingCharacters(in: .whitespaces))
            return nil
        }
        if line == "@@END" {
            current = nil
            return build()
        }
        if line.hasPrefix("@@"), !line.contains(" ") {
            current = String(line.dropFirst(2))
            sections[current!] = []
            return nil
        }
        if let current { sections[current, default: []].append(line) }
        return nil
    }

    private mutating func build() -> RemoteSnapshot? {
        guard let time else { return nil }
        var snapshot = RemoteSnapshot()
        let now = Date(timeIntervalSince1970: TimeInterval(time))

        // Compteurs cumulés → débits par différence.
        let cpu = (sections["STAT"] ?? []).map { line in line.split(separator: " ").dropFirst().prefix(8).map { Int64($0) ?? 0 } }
        let (netIn, netOut) = Self.network(sections["NET"] ?? [])
        let (reads, writes) = Self.diskSectors(sections["IO"] ?? [])
        let counters = Counters(time: time, cpu: cpu, netIn: netIn, netOut: netOut, readSectors: reads, writeSectors: writes)
        let memory = Self.memory(sections["MEM"] ?? [])
        let load = (sections["LOAD"]?.first ?? "").split(separator: " ").prefix(3).compactMap { Double($0) }

        let interval = previous.map { Double(max(1, time - $0.time)) } ?? 2
        if let previous, counters.time > previous.time, !cpu.isEmpty, previous.cpu.count == cpu.count {
            let seconds = Double(counters.time - previous.time)
            func usage(_ new: [Int64], _ old: [Int64]) -> (Double, Double) {
                guard new.count >= 5, old.count >= 5 else { return (0, 0) }
                let total = Double(zip(new, old).map { $0 - $1 }.reduce(0, +))
                guard total > 0 else { return (0, 0) }
                let idle = Double((new[3] - old[3]) + (new[4] - old[4]))
                let wait = Double(new[4] - old[4])
                return (max(0, min(100, (1 - idle / total) * 100)), max(0, wait / total * 100))
            }
            let (total, wait) = usage(cpu[0], previous.cpu[0])
            let cores = zip(cpu.dropFirst(), previous.cpu.dropFirst()).map { usage($0, $1).0 }
            func rate(_ new: Int64, _ old: Int64) -> Double { max(0, Double(new - old) / seconds) }
            snapshot.sample = RemoteSample(
                time: now, cpu: total, cores: cores, iowait: wait, load: load,
                memoryTotal: memory.total, memoryUsed: memory.used, memoryCached: memory.cached,
                swapTotal: memory.swapTotal, swapUsed: memory.swapUsed,
                networkIn: rate(netIn, previous.netIn), networkOut: rate(netOut, previous.netOut),
                diskRead: rate(reads, previous.readSectors) * 512, diskWrite: rate(writes, previous.writeSectors) * 512
            )
        }
        previous = counters

        if let info = sections["INFO"] {
            snapshot.info = Self.info(info)
            if info.count > 7, let ticks = Double(info[7].trimmingCharacters(in: .whitespaces)), ticks > 0 { hz = ticks }
        }
        var ticks: [Int32: Double] = [:]
        for line in sections["CPU"] ?? [] {
            let parts = line.split(separator: " ")
            if parts.count == 2, let pid = Int32(parts[0]), let delta = Double(parts[1]) { ticks[pid] = delta }
        }
        let hz = hz
        snapshot.processes = Self.processes(sections["PS"] ?? [], now: time).map { process in
            var process = process
            process.cpu = (ticks[process.pid] ?? 0) / (hz * interval) * 100
            return process
        }
        .sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.resident > $1.resident }
        if let lines = sections["DF"] { snapshot.disks = Self.disks(lines) }
        if let lines = sections["PORTS"] {
            snapshot.portsAvailability = lines.first == "!absent" ? .absent : .available
            snapshot.ports = Self.ports(lines)
        }
        if let lines = sections["SERVICES"] {
            snapshot.servicesAvailability = lines.first == "!absent" ? .absent : .available
            snapshot.services = Self.services(lines)
        }
        if let lines = sections["DOCKER"] {
            snapshot.dockerAvailability = lines.first == "!absent" ? .absent : lines.first == "!denied" ? .denied : .available
            snapshot.containers = Self.containers(lines, stats: sections["DSTATS"] ?? [])
        }
        return snapshot
    }

    // MARK: Sections

    static func memory(_ lines: [String]) -> (total: Int64, used: Int64, cached: Int64, swapTotal: Int64, swapUsed: Int64) {
        var values: [String: Int64] = [:]
        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            values[String(parts[0].dropLast())] = (Int64(parts[1]) ?? 0) * 1024
        }
        let total = values["MemTotal"] ?? 0
        let available = values["MemAvailable"] ?? ((values["MemFree"] ?? 0) + (values["Cached"] ?? 0) + (values["Buffers"] ?? 0))
        let cached = (values["Cached"] ?? 0) + (values["Buffers"] ?? 0) + (values["SReclaimable"] ?? 0)
        let swapTotal = values["SwapTotal"] ?? 0
        return (total, max(0, total - available), cached, swapTotal, max(0, swapTotal - (values["SwapFree"] ?? 0)))
    }

    /// Interfaces physiques et VPN (pas lo, ni les ponts et interfaces virtuelles de Docker).
    static func network(_ lines: [String]) -> (Int64, Int64) {
        var received: Int64 = 0
        var sent: Int64 = 0
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            if name == "lo" || ["veth", "docker", "br-", "virbr", "cni", "flannel", "cali"].contains(where: { name.hasPrefix($0) }) { continue }
            let fields = parts[1].split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 9 else { continue }
            received += Int64(fields[0]) ?? 0
            sent += Int64(fields[8]) ?? 0
        }
        return (received, sent)
    }

    /// Disques entiers seulement (sda, vda, nvme0n1, mmcblk0), pas leurs partitions.
    static func diskSectors(_ lines: [String]) -> (Int64, Int64) {
        var reads: Int64 = 0
        var writes: Int64 = 0
        for line in lines {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 10 else { continue }
            let name = String(fields[2])
            guard name.range(of: #"^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|nvme\d+n\d+|mmcblk\d+)$"#, options: .regularExpression) != nil else { continue }
            reads += Int64(fields[5]) ?? 0
            writes += Int64(fields[9]) ?? 0
        }
        return (reads, writes)
    }

    static func processes(_ lines: [String], now: Int) -> [RemoteProcess] {
        lines.compactMap { line in
            var rest = Substring(line)
            var fields: [Substring] = []
            for _ in 0..<8 {
                rest = rest.drop { $0 == " " }
                guard let end = rest.firstIndex(of: " ") else { return nil }
                fields.append(rest[..<end])
                rest = rest[end...]
            }
            let command = rest.trimmingCharacters(in: .whitespaces)
            guard let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { return nil }
            let elapsed = Int(fields[6]) ?? 0
            return RemoteProcess(
                pid: pid, ppid: ppid, user: String(fields[2]), cpu: Double(fields[3]) ?? 0, memoryPercent: Double(fields[4]) ?? 0,
                resident: (Int64(fields[5]) ?? 0) * 1024, elapsed: elapsed, state: String(fields[7]), command: command,
                started: now - elapsed
            )
        }
    }

    static func info(_ lines: [String]) -> RemoteSystemInfo {
        func at(_ index: Int) -> String { index < lines.count ? lines[index].trimmingCharacters(in: .whitespaces) : "" }
        var info = RemoteSystemInfo()
        info.hostname = at(0)
        info.os = at(1)
        info.kernel = at(2)
        info.uptime = TimeInterval(at(3)) ?? 0
        info.users = Int(at(4)) ?? 0
        info.login = at(5)
        info.isRoot = at(6) == "0"
        info.canSudo = lines.contains("sudo") || info.isRoot
        return info
    }

    static func disks(_ lines: [String]) -> [RemoteDisk] {
        lines.compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
            guard fields.count == 7, let size = Int64(fields[2]), size > 0 else { return nil }
            return RemoteDisk(device: String(fields[0]), type: String(fields[1]), size: size * 1024,
                              used: (Int64(fields[3]) ?? 0) * 1024, available: (Int64(fields[4]) ?? 0) * 1024, mount: String(fields[6]))
        }
        .filter { !$0.mount.hasPrefix("/snap/") && !$0.mount.hasPrefix("/boot/efi") }
    }

    /// `tcp LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=812,fd=3))`
    static func ports(_ lines: [String]) -> [RemotePort] {
        var seen = Set<String>()
        return lines.compactMap { line -> RemotePort? in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, !line.hasPrefix("!") else { return nil }
            // `ss -tln` n'affiche pas la colonne du protocole : « LISTEN 0 4096 0.0.0.0:22 … ».
            let tcpOnly = fields[0] == "LISTEN"
            guard fields.count >= (tcpOnly ? 4 : 5) else { return nil }
            let local = String(fields[tcpOnly ? 3 : 4])
            guard let colon = local.lastIndex(of: ":"), let number = Int(local[local.index(after: colon)...]) else { return nil }
            var address = String(local[..<colon])
            address = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
            if address == "*" || address == "::" || address == "0.0.0.0" { address = "0.0.0.0" }
            let process = line.range(of: #"\(\("([^"]+)""#, options: .regularExpression).map { String(line[$0].dropFirst(3).dropLast()) }
            let pid = line.range(of: #"pid=\d+"#, options: .regularExpression).flatMap { Int32(line[$0].dropFirst(4)) }
            let port = RemotePort(proto: tcpOnly ? "tcp" : String(fields[0]), address: address, port: number, process: process, pid: pid)
            return seen.insert("\(port.proto)-\(port.port)-\(address)").inserted ? port : nil
        }
        .sorted { ($0.port, $0.proto) < ($1.port, $1.proto) }
    }

    static func services(_ lines: [String]) -> [RemoteService] {
        lines.compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count >= 4, !line.hasPrefix("!") else { return nil }
            var name = String(fields[0])
            if name.hasSuffix(".service") { name = String(name.dropLast(8)) }
            return RemoteService(name: name, active: String(fields[2]), sub: String(fields[3]),
                                 description: fields.count > 4 ? String(fields[4]) : "")
        }
        .sorted { a, b in a.failed != b.failed ? a.failed : a.name < b.name }
    }

    static func containers(_ lines: [String], stats: [String]) -> [RemoteContainer] {
        var usage: [String: (Double?, String, Double?)] = [:]
        for line in stats {
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 4 else { continue }
            usage[fields[0]] = (Double(fields[1].replacingOccurrences(of: "%", with: "")), fields[2],
                                Double(fields[3].replacingOccurrences(of: "%", with: "")))
        }
        return lines.compactMap { line in
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 5, !line.hasPrefix("!") else { return nil }
            let stat = usage[fields[0]] ?? usage.first { fields[0].hasPrefix($0.key) || $0.key.hasPrefix(fields[0]) }?.value
            return RemoteContainer(id: fields[0], name: fields[1], image: fields[2], state: fields[3], status: fields[4],
                                   cpu: stat?.0, memory: stat?.1, memoryPercent: stat?.2)
        }
        .sorted { a, b in a.running != b.running ? a.running : a.name < b.name }
    }
}

// MARK: - Actions (toujours avec aperçu)

public enum RemoteActions {
    /// Arrête un processus après avoir vérifié que le PID désigne toujours le même processus
    /// (date de lancement à ±3 s), pour ne jamais tuer un autre programme qui aurait repris le numéro.
    public static func kill(_ process: RemoteProcess, force: Bool, sudo: Bool) -> String {
        let signal = force ? "KILL" : "TERM"
        let pid = process.pid
        return """
        e=$(ps -o etimes= -p \(pid) 2>/dev/null | tr -d ' '); \
        if [ -z "$e" ]; then echo "Le processus \(pid) n’existe plus." >&2; exit 1; fi; \
        d=$(( $(date +%s) - e - \(process.started) )); \
        if [ $d -lt -3 ] || [ $d -gt 3 ]; then echo "Le PID \(pid) désigne maintenant un autre processus : rien n’a été arrêté." >&2; exit 1; fi; \
        \(sudo ? "sudo -n " : "")kill -\(signal) \(pid)
        """
    }

    public enum ServiceAction: String, Sendable, CaseIterable {
        case restart, stop, start

        public var label: String {
            switch self {
            case .restart: "Redémarrer"
            case .stop: "Arrêter"
            case .start: "Démarrer"
            }
        }
    }

    public static func service(_ name: String, _ action: ServiceAction, sudo: Bool) -> String {
        "\(sudo ? "sudo -n " : "")systemctl \(action.rawValue) -- \(ShellQuote.quote(name + ".service"))"
    }

    public static func container(_ name: String, _ action: ServiceAction, sudo: Bool) -> String {
        "\(sudo ? "sudo -n " : "")docker \(action.rawValue) \(ShellQuote.quote(name))"
    }

    /// Les journaux, à suivre dans le terminal.
    public static func serviceLogs(_ name: String) -> String {
        "journalctl -u \(ShellQuote.quote(name + ".service")) -n 200 -f"
    }

    public static func containerLogs(_ name: String) -> String {
        "docker logs -f --tail 200 \(ShellQuote.quote(name))"
    }
}
