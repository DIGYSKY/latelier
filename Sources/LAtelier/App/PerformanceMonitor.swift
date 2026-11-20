import AppKit
import LAtelierCore
import Observation

/// Mesures hors du fil principal : `ps`, `lsof` et `nettop` peuvent prendre du temps.
actor PerformanceEngine {
    private var system = SystemSampler()
    private var processes: ProcessSampler
    private let ports: PortScanner
    private let runner: CommandRunner

    init(runner: CommandRunner) {
        self.runner = runner
        processes = ProcessSampler(runner: runner)
        ports = PortScanner(runner: runner)
    }

    var machine: MachineInfo { system.machine }

    func tick() async -> (SystemSample, [RunningProcess]) {
        let sample = system.sample()
        var sampler = processes
        let list = await sampler.sample()
        processes = sampler
        return (sample, list)
    }

    func network() async -> ([ListeningPort], [Int32: ProcessConnections], IOCounters?) {
        async let listening = ports.listening()
        async let connections = ports.connections()
        async let totals = SystemSampler.bootTraffic(runner: runner)
        return await (listening, connections, totals)
    }
}

actor TrafficEngine {
    private var sampler: TrafficSampler

    init(runner: CommandRunner) {
        sampler = TrafficSampler(runner: runner)
    }

    func sample() async -> [Int32: TrafficSampler.Rate] {
        var copy = sampler
        let rates = await copy.sample()
        sampler = copy
        return rates
    }
}

/// Gestionnaire des tâches : échantillonne chaque seconde tant qu'un écran Performance est affiché
/// et que la fenêtre est visible (règle de sobriété du cahier des charges).
@Observable
final class PerformanceMonitor {
    static let historyLength = 60

    let machine: MachineInfo
    private(set) var latest: SystemSample?
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    private(set) var gpuHistory: [Double] = []
    private(set) var networkHistory: [Double] = []
    private(set) var diskHistory: [Double] = []
    private(set) var processes: [RunningProcess] = []
    private(set) var ports: [ListeningPort] = []
    private(set) var connections: [Int32: ProcessConnections] = [:]
    private(set) var traffic: [Int32: TrafficSampler.Rate] = [:]
    /// Octets reçus / envoyés depuis le démarrage (compteurs complets, via netstat).
    private(set) var bootTraffic: IOCounters?
    private(set) var trafficReady = false
    private(set) var bootTime = Sysctl.bootTime()
    var paused = false

    @ObservationIgnored private let engine: PerformanceEngine
    @ObservationIgnored private let trafficEngine: TrafficEngine
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var trafficLoop: Task<Void, Never>?

    init(runner: CommandRunner) {
        machine = .current()
        engine = PerformanceEngine(runner: runner)
        trafficEngine = TrafficEngine(runner: runner)
    }

    /// Un écran Performance apparaît : on démarre l'échantillonnage s'il ne tourne pas.
    func attach() {
        viewers += 1
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                // Première mesure toujours faite, pour ne pas afficher un écran vide.
                if !self.paused && (Self.windowVisible || self.latest == nil) {
                    await self.refresh(networkToo: tick % 3 == 0)
                    tick += 1
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        trafficLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.paused && (Self.windowVisible || !self.trafficReady) {
                    // nettop mesure pendant ~5 s : la boucle se cadence toute seule.
                    let rates = await self.trafficEngine.sample()
                    guard !Task.isCancelled else { return }
                    self.traffic = rates
                    self.trafficReady = true
                } else {
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    func detach() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        // Petit délai : passer d'un écran Performance à l'autre ne relance pas tout.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.viewers == 0 else { return }
            self.loop?.cancel()
            self.trafficLoop?.cancel()
            self.loop = nil
            self.trafficLoop = nil
        }
    }

    /// Mesure immédiate (après avoir quitté un processus, par exemple).
    func refreshNow() {
        Task { await refresh(networkToo: true) }
    }

    private func refresh(networkToo: Bool) async {
        let (sample, list) = await engine.tick()
        latest = sample
        processes = list
        Self.push(&cpuHistory, sample.cpu)
        Self.push(&memoryHistory, Double(sample.memory.used))
        Self.push(&gpuHistory, sample.gpu?.utilization ?? 0)
        Self.push(&networkHistory, sample.networkIn + sample.networkOut)
        Self.push(&diskHistory, sample.diskRead + sample.diskWrite)
        if networkToo {
            let (listening, established, totals) = await engine.network()
            ports = listening
            connections = established
            if let totals { bootTraffic = totals }
        }
    }

    private static func push(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }

    private static var windowVisible: Bool {
        // Captures d'écran avec la fenêtre sur un autre bureau.
        if ProcessInfo.processInfo.environment["LATELIER_ALWAYS_SAMPLE"] == "1" { return true }
        return NSApp.occlusionState.contains(.visible) && NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized }
    }

    func process(_ pid: Int32) -> RunningProcess? { processes.first { $0.pid == pid } }
}
