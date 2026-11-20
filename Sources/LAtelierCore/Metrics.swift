import Darwin
import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration

/// Description de la machine, pour l'en-tête de Performance.
public struct MachineInfo: Sendable, Equatable {
    public var chip: String
    public var performanceCores: Int
    public var efficiencyCores: Int
    public var memory: Int64

    public var cores: Int { performanceCores + efficiencyCores }

    public static func current() -> MachineInfo {
        let total = Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        let perf = Sysctl.int("hw.perflevel0.logicalcpu") ?? total
        let eff = Sysctl.int("hw.perflevel1.logicalcpu") ?? 0
        return MachineInfo(
            chip: Sysctl.string("machdep.cpu.brand_string") ?? "Mac",
            performanceCores: perf, efficiencyCores: perf + eff == total ? eff : max(0, total - perf),
            memory: Int64(ProcessInfo.processInfo.physicalMemory)
        )
    }
}

public enum Sysctl {
    public static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        // Les entrées 32 bits ne remplissent que les 4 premiers octets.
        return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }

    public static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(nulTerminated: buffer)
    }

    public static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }
}

// MARK: - Mesures

public enum MemoryPressure: Int, Sendable {
    case normal = 1, warning = 2, critical = 4

    public var label: String {
        switch self {
        case .normal: "normale"
        case .warning: "élevée"
        case .critical: "critique"
        }
    }
}

public struct MemorySnapshot: Sendable, Equatable {
    public var total: Int64
    /// Mémoire des apps (pages anonymes, hors purgeable).
    public var app: Int64
    public var wired: Int64
    public var compressed: Int64
    /// Fichiers en cache (récupérables à tout moment).
    public var cached: Int64
    public var swapUsed: Int64
    public var swapTotal: Int64
    public var pressure: MemoryPressure

    /// « Mémoire utilisée » au sens du Moniteur d'activité.
    public var used: Int64 { app + wired + compressed }
}

public struct GPUSnapshot: Sendable, Equatable {
    public var utilization: Double
    public var memoryInUse: Int64?
}

/// Compteurs cumulés depuis le démarrage (octets).
public struct IOCounters: Sendable, Equatable {
    public var read: UInt64
    public var written: UInt64
}

public struct NetworkSnapshot: Sendable, Equatable {
    /// Octets reçus / envoyés depuis le démarrage, interfaces physiques.
    public var counters: IOCounters
    public var primaryInterface: String?
    /// Nom lisible (« Wi-Fi », « Ethernet »).
    public var primaryName: String?
    public var localAddress: String?
    public var vpnActive: Bool
}

public struct PowerSnapshot: Sendable, Equatable {
    public var batteryLevel: Int?
    public var charging: Bool
    public var onBattery: Bool
    public var thermal: ProcessInfo.ThermalState

    /// État de l'alimentation maintenant (batterie, secteur).
    public static func current() -> PowerSnapshot { SystemSampler.power() }

    public var thermalLabel: String {
        switch thermal {
        case .nominal: "normal"
        case .fair: "tiède"
        case .serious: "chaud"
        case .critical: "critique"
        @unknown default: "inconnu"
        }
    }
}

/// Une mesure de l'ensemble de la machine, avec les débits calculés depuis la précédente.
public struct SystemSample: Sendable {
    public var date: Date
    /// Charge totale, 0…100.
    public var cpu: Double
    /// Charge par cœur, 0…100, dans l'ordre du noyau.
    public var cores: [Double]
    public var performanceLoad: Double
    public var efficiencyLoad: Double
    public var memory: MemorySnapshot
    public var gpu: GPUSnapshot?
    public var network: NetworkSnapshot
    /// Octets par seconde.
    public var networkIn: Double
    public var networkOut: Double
    public var diskRead: Double
    public var diskWrite: Double
    public var diskFree: Int64?
    public var power: PowerSnapshot
}

/// Échantillonneur : garde les compteurs précédents pour calculer charges et débits.
public struct SystemSampler: Sendable {
    public let machine: MachineInfo
    private var previousTicks: [[UInt32]] = []
    private var previousNetwork: IOCounters?
    private var previousDisk: IOCounters?
    private var previousDate: Date?

    public init(machine: MachineInfo = .current()) {
        self.machine = machine
    }

    public mutating func sample(now: Date = Date()) -> SystemSample {
        let ticks = Self.cpuTicks()
        var cores: [Double] = []
        if ticks.count == previousTicks.count {
            for (new, old) in zip(ticks, previousTicks) {
                cores.append(Self.load(new: new, old: old))
            }
        } else {
            cores = ticks.map { Self.load(new: $0, old: [0, 0, 0, 0]) }
        }
        previousTicks = ticks

        // Sur Apple Silicon, les cœurs d'efficacité viennent en premier.
        let eff = machine.efficiencyCores
        let effCores = cores.prefix(eff)
        let perfCores = cores.dropFirst(eff)
        func mean<C: Collection>(_ c: C) -> Double where C.Element == Double { c.isEmpty ? 0 : c.reduce(0, +) / Double(c.count) }

        let network = Self.network()
        let disk = Self.diskCounters()
        let elapsed = previousDate.map { now.timeIntervalSince($0) } ?? 0
        func rate(_ new: UInt64, _ old: UInt64?) -> Double {
            guard let old, elapsed > 0.05, new >= old else { return 0 }
            return Double(new - old) / elapsed
        }
        let sample = SystemSample(
            date: now,
            cpu: mean(cores),
            cores: cores,
            performanceLoad: mean(perfCores),
            efficiencyLoad: mean(effCores),
            memory: Self.memory(total: machine.memory),
            gpu: Self.gpu(),
            network: network,
            networkIn: Self.wrappingRate(network.counters.read, previousNetwork?.read, elapsed: elapsed),
            networkOut: Self.wrappingRate(network.counters.written, previousNetwork?.written, elapsed: elapsed),
            diskRead: rate(disk.read, previousDisk?.read),
            diskWrite: rate(disk.written, previousDisk?.written),
            diskFree: (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage,
            power: Self.power()
        )
        previousNetwork = network.counters
        previousDisk = disk
        previousDate = now
        return sample
    }

    /// Hors binaires Apple, le noyau ne donne que les 32 bits bas des compteurs réseau :
    /// l'écart se calcule modulo 2³² (exact tant qu'on reste sous 4 Go entre deux mesures).
    static func wrappingRate(_ new: UInt64, _ old: UInt64?, elapsed: TimeInterval) -> Double {
        guard let old, elapsed > 0.05 else { return 0 }
        let delta = UInt32(truncatingIfNeeded: new) &- UInt32(truncatingIfNeeded: old)
        return Double(delta) / elapsed
    }

    /// Totaux complets depuis le démarrage (`netstat` a les compteurs 64 bits), interfaces `en*`.
    public static func bootTraffic(runner: CommandRunner) async -> IOCounters? {
        guard let result = try? await runner.run(CommandSpec("/usr/sbin/netstat", ["-ib"]), timeout: .seconds(5)) else { return nil }
        return parseNetstat(result.stdout)
    }

    static func parseNetstat(_ lines: [String]) -> IOCounters? {
        var total = IOCounters(read: 0, written: 0)
        var found = false
        for line in lines {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            // Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll — une ligne <Link#> par interface.
            guard f.count >= 10, f[0].hasPrefix("en"), f[2].hasPrefix("<Link#"),
                  let ibytes = UInt64(f[6]), let obytes = UInt64(f[9]) else { continue }
            total.read += ibytes
            total.written += obytes
            found = true
        }
        return found ? total : nil
    }

    static func load(new: [UInt32], old: [UInt32]) -> Double {
        // user, system, idle, nice ; les compteurs 32 bits peuvent reboucler.
        let d = (0..<4).map { Double(new[$0] &- old[$0]) }
        let busy = d[0] + d[1] + d[3]
        let total = busy + d[2]
        return total > 0 ? min(100, busy / total * 100) : 0
    }

    // MARK: Sources

    static func cpuTicks() -> [[UInt32]] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { cpu in
            (0..<states).map { UInt32(bitPattern: info[cpu * states + $0]) }
        }
    }

    static func memory(total: Int64) -> MemorySnapshot {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let page = Int64(getpagesize())
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let hasSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
        let pressure = MemoryPressure(rawValue: Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1) ?? .normal
        guard result == KERN_SUCCESS else {
            return MemorySnapshot(total: total, app: 0, wired: 0, compressed: 0, cached: 0, swapUsed: 0, swapTotal: 0, pressure: pressure)
        }
        let purgeable = Int64(stats.purgeable_count)
        return MemorySnapshot(
            total: total,
            app: max(0, Int64(stats.internal_page_count) - purgeable) * page,
            wired: Int64(stats.wire_count) * page,
            compressed: Int64(stats.compressor_page_count) * page,
            cached: (Int64(stats.external_page_count) + purgeable) * page,
            swapUsed: hasSwap ? Int64(swap.xsu_used) : 0,
            swapTotal: hasSwap ? Int64(swap.xsu_total) : 0,
            pressure: pressure
        )
    }

    static func gpu() -> GPUSnapshot? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: GPUSnapshot?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let raw = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue(), let stats = raw as? [String: Any] else { continue }
            let utilization = (stats["Device Utilization %"] as? NSNumber)?.doubleValue ?? 0
            let memory = (stats["In use system memory"] as? NSNumber)?.int64Value
            if best == nil || utilization > best!.utilization {
                best = GPUSnapshot(utilization: utilization, memoryInUse: memory)
            }
        }
        return best
    }

    static func diskCounters() -> IOCounters {
        var iterator: io_iterator_t = 0
        var total = IOCounters(read: 0, written: 0)
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return total }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let raw = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue(), let stats = raw as? [String: Any] else { continue }
            total.read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            total.written &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return total
    }

    /// Interfaces physiques (`en*`) : on évite de compter deux fois le trafic d'un VPN.
    static func network() -> NetworkSnapshot {
        var counters = IOCounters(read: 0, written: 0)
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        if sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 {
            var buffer = [UInt8](repeating: 0, count: length)
            if sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 {
                buffer.withUnsafeBytes { raw in
                    var offset = 0
                    while offset + MemoryLayout<if_msghdr>.size <= length {
                        let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                        if Int32(header.ifm_type) == RTM_IFINFO2 {
                            let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                            if if_indextoname(UInt32(message.ifm_index), &name) != nil,
                               String(nulTerminated: name).hasPrefix("en"), message.ifm_flags & IFF_UP != 0 {
                                counters.read &+= message.ifm_data.ifi_ibytes
                                counters.written &+= message.ifm_data.ifi_obytes
                            }
                        }
                        guard header.ifm_msglen > 0 else { break }
                        offset += Int(header.ifm_msglen)
                    }
                }
            }
        }

        let primary = primaryInterface()
        var address: String?
        var vpn = false
        var addrs: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&addrs) == 0, let first = addrs {
            defer { freeifaddrs(addrs) }
            for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let entry = pointer.pointee
                guard let sa = entry.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
                let name = String(cString: entry.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let ip = String(nulTerminated: host)
                if name == primary { address = ip }
                if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") || name.hasPrefix("tun") || name.hasPrefix("wg") {
                    if !ip.hasPrefix("169.254.") { vpn = true }
                }
            }
        }
        return NetworkSnapshot(
            counters: counters, primaryInterface: primary, primaryName: primary.flatMap(interfaceName),
            localAddress: address, vpnActive: vpn
        )
    }

    static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "LAtelier" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return nil }
        return value["PrimaryInterface"] as? String
    }

    static func interfaceName(_ bsd: String) -> String? {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        for interface in all where SCNetworkInterfaceGetBSDName(interface) as String? == bsd {
            return SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
        }
        return nil
    }

    static func power() -> PowerSnapshot {
        var snapshot = PowerSnapshot(batteryLevel: nil, charging: false, onBattery: false, thermal: ProcessInfo.processInfo.thermalState)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return snapshot }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            if let current = description[kIOPSCurrentCapacityKey] as? Int, let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 {
                snapshot.batteryLevel = current * 100 / max
            }
            snapshot.charging = description[kIOPSIsChargingKey] as? Bool ?? false
            snapshot.onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
        }
        return snapshot
    }
}

extension String {
    /// Tampon C terminé par un zéro.
    init(nulTerminated buffer: [CChar]) {
        self.init(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
