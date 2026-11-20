import Foundation
import Testing
@testable import LAtelierCore

@Suite struct PerformanceTests {
    @Test func cpuLoadFromTicks() {
        // user, system, idle, nice
        #expect(SystemSampler.load(new: [150, 50, 300, 0], old: [100, 0, 200, 0]) == 50)
        #expect(SystemSampler.load(new: [5, 0, 5, 0], old: [5, 0, 5, 0]) == 0)
        // Compteurs qui rebouclent.
        #expect(SystemSampler.load(new: [9, 0, 10, 0], old: [UInt32.max - 0, 0, 0, 0]) == 50)
    }

    @Test func networkCountersWrap() {
        // Compteur 32 bits passé de 4 294 967 000 à 704 : 1 000 octets en 1 s.
        #expect(SystemSampler.wrappingRate(704, 4_294_967_000, elapsed: 1) == 1000)
        #expect(SystemSampler.wrappingRate(5000, nil, elapsed: 1) == 0)
        let totals = SystemSampler.parseNetstat([
            "Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll",
            "lo0        16384 <Link#1>                        100     0     5000      100     0     5000     0",
            "en0        1500  <Link#12>   fa:e3:d1:f5:10:c9 48530435     0 60201598457  8627704     0 3184140388     0",
            "en0        1500  fe80::1     fe80:c::1c6f:b300 48530435     - 60201598457  8627704     - 3184140388     -",
            "en1        1500  <Link#13>   aa:bb:cc:dd:ee:ff 0     0 0  0     0 0     0",
        ])
        #expect(totals == IOCounters(read: 60_201_598_457, written: 3_184_140_388))
    }

    @Test func parsesPS() {
        let lines = [
            "  221     1    88   4,0  61232 Tue Nov 18 09:12:01 2026     /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
            "    0     0     0  12.5      0 Mon Nov 17 08:00:00 2026     kernel_task",
            " 5133  5120   501   9,4 921600 Thu Nov 20 10:01:02 2026     /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)",
        ]
        let processes = ProcessSampler.parsePS(lines)
        #expect(processes.count == 3)
        #expect(processes[221]?.name == "WindowServer")
        #expect(processes[221]?.uid == 88)
        #expect(processes[221]?.cpu == 4)
        #expect(processes[221]?.isSystem == true)
        #expect(processes[0]?.name == "kernel_task")
        #expect(processes[0]?.cpu == 12.5)
        let helper = processes[5133]!
        #expect(helper.name == "Google Chrome Helper (GPU)")
        #expect(helper.memory == 921600 * 1024)
        #expect(helper.appBundle == "/Applications/Google Chrome.app")
        #expect(helper.started > 0)
    }

    @Test func groupsByOuterApp() {
        func process(_ pid: Int32, _ ppid: Int32, _ path: String, cpu: Double) -> RunningProcess {
            RunningProcess(pid: pid, ppid: ppid, uid: getuid(), name: (path as NSString).lastPathComponent, path: path,
                           started: 1, cpu: cpu, memory: 100, threads: 2, wakeups: 0, cwd: nil, detailed: true)
        }
        var node = process(4821, 1, "/opt/homebrew/bin/node", cpu: 38)
        node.cwd = "/Users/me/projects/old-shop/server"
        let groups = ProcessGroup.group([
            process(5120, 1, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", cpu: 6),
            process(5133, 5120, "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)", cpu: 9),
            node,
            process(4900, 1, "/opt/homebrew/bin/node", cpu: 1),
        ], projects: [URL(fileURLWithPath: "/Users/me/projects/old-shop"), URL(fileURLWithPath: "/Users/me/projects")])
        let chrome = groups.first { $0.name == "Google Chrome" }!
        #expect(chrome.processes.count == 2)
        #expect(chrome.cpu == 15)
        #expect(chrome.threads == 4)
        // Quitter Chrome = quitter l'app principale, pas ses assistants.
        #expect(chrome.quitTargets.map(\.pid) == [5120])
        #expect(chrome.quitTargets.first?.isApp == true)
        let nodes = groups.first { $0.name == "node" }!
        #expect(nodes.processes.count == 2)
        #expect(nodes.project?.lastPathComponent == "old-shop")
        #expect(nodes.isDev)
        #expect(Set(nodes.quitTargets.map(\.pid)) == [4821, 4900])
    }

    @Test func systemProcessesAreReadOnly() {
        let finder = RunningProcess(pid: 600, ppid: 1, uid: getuid(), name: "Finder", path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
                                    started: 1, cpu: 0, memory: 0, threads: nil, wakeups: 0, cwd: nil, detailed: true)
        #expect(!finder.canQuit)
        let root = RunningProcess(pid: 700, ppid: 1, uid: 0, name: "postgres", path: "/opt/homebrew/bin/postgres",
                                  started: 1, cpu: 0, memory: 0, threads: nil, wakeups: 0, cwd: nil, detailed: false)
        #expect(!root.canQuit)
        let me = RunningProcess(pid: getpid(), ppid: 1, uid: getuid(), name: "LAtelier", path: "/Users/me/LAtelier",
                                started: 1, cpu: 0, memory: 0, threads: nil, wakeups: 0, cwd: nil, detailed: true)
        #expect(!me.canQuit)
    }

    @Test func energyImpact() {
        #expect(EnergyImpact(cpu: 0, wakeups: 0) == .none)
        #expect(EnergyImpact(cpu: 1, wakeups: 0) == .low)
        #expect(EnergyImpact(cpu: 2, wakeups: 500) == .medium)
        #expect(EnergyImpact(cpu: 40, wakeups: 0) == .high)
    }

    @Test func parsesListeningPorts() {
        let lines = ["p4821", "cnode", "f20", "n*:3000", "f21", "n[::]:3000", "p13156", "cRaycast", "f35", "n127.0.0.1:7265",
                     "p20441", "ccom.docker.backend", "f136", "n[::1]:5432"]
        let ports = PortScanner.parseListening(lines)
        #expect(ports.map(\.port) == [3000, 5432, 7265])
        #expect(ports[0].addresses == ["*", "[::]"])
        #expect(ports[0].exposed)
        #expect(ports[0].displayAddress == "0.0.0.0")
        #expect(!ports[1].exposed)
        #expect(!ports[2].exposed)
        #expect(ports[2].command == "Raycast")
    }

    @Test func parsesConnections() {
        let lines = ["p5120", "f30", "n192.168.1.20:52144->140.82.112.3:443", "f31", "n192.168.1.20:52145->140.82.112.3:443",
                     "f32", "n[2a01::1]:5000->[2606:4700::1]:443", "p48234", "n127.0.0.1:5000->127.0.0.1:3000"]
        let connections = PortScanner.parseConnections(lines)
        #expect(connections[5120]?.count == 3)
        #expect(connections[5120]?.hosts == ["140.82.112.3", "[2606:4700::1]"])
        #expect(connections[48234]?.hosts == [])
    }

    @Test func parsesNettop() {
        let lines = [",bytes_in,bytes_out,", "apsd.144,18436,39616,", "com.apple.geod.598,6202,8878,", "Google Chrome H.5133,10,20,", "garbage"]
        let parsed = TrafficSampler.parse(lines)
        #expect(parsed.count == 3)
        #expect(parsed[598]?.name == "com.apple.geod")
        #expect(parsed[598]?.down == 6202)
        #expect(parsed[5133]?.name == "Google Chrome H")
    }

    @Test func quitPlanUsesSignals() throws {
        let plan = try #require(ProcessActions.quitPlan([ProcessTarget(pid: 4821, name: "node", started: 10)], label: "node", force: true))
        #expect(plan.kind == .processus)
        #expect(plan.risk == .danger)
        #expect(plan.steps.first?.displayString == "kill -KILL 4821   # node")
        #expect(plan.steps.first?.isCommandLike == true)
        let app = ActionStep.signal(ProcessTarget(pid: 5120, name: "Google Chrome", started: 10, isApp: true), force: false)
        #expect(app.displayString == "quitter « Google Chrome » (PID 5120)")
        #expect(ProcessActions.quitPlan([], label: "x", force: false) == nil)
    }

    @Test func refusesStaleTarget() async {
        // Même PID, autre date de début : ce n'est plus le même processus.
        let target = ProcessTarget(pid: getpid(), name: "moi", started: 1)
        #expect(!target.isAlive)
        await #expect(throws: ProcessTerminator.Failure.self) {
            _ = try await ProcessTerminator.terminate(target, force: false)
        }
    }

    @Test func projectMatcherPicksDeepest() {
        let projects = [URL(fileURLWithPath: "/a/projects"), URL(fileURLWithPath: "/a/projects/shop")]
        #expect(ProjectMatcher.project(for: "/a/projects/shop/src", in: projects)?.lastPathComponent == "shop")
        #expect(ProjectMatcher.project(for: "/a/projects-old", in: projects) == nil)
    }
}

@Suite struct StartupTests {
    @Test func parsesLaunchPlist() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>Label</key><string>us.zoom.updater</string>
        <key>ProgramArguments</key><array><string>/Applications/zoom.us.app/Contents/Frameworks/ZoomUpdater</string><string>--check</string></array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
        </dict></plist>
        """
        let plist = try #require(LaunchPlist.parse(Data(xml.utf8)))
        #expect(plist.label == "us.zoom.updater")
        #expect(plist.program == "/Applications/zoom.us.app/Contents/Frameworks/ZoomUpdater")
        #expect(plist.impact == .high)
        #expect(plist.orphan)
        #expect(StartupScanner.appName(plist.program) == "zoom.us")
        #expect(StartupScanner.describe(plist, orphan: true) == "zoom.us n’est plus installé")

        let periodic = try #require(LaunchPlist.parse(Data("""
        <plist version="1.0"><dict><key>Label</key><string>x</string><key>Program</key><string>/usr/bin/true</string>
        <key>StartInterval</key><integer>3600</integer></dict></plist>
        """.utf8)))
        #expect(periodic.impact == .low)
        #expect(!periodic.orphan)
        #expect(StartupScanner.describe(periodic, orphan: false) == "à la demande · périodique".replacingOccurrences(of: "à la demande · ", with: ""))
    }

    @Test func parsesLaunchctl() {
        let disabled = StartupScanner.parseDisabled([
            "disabled services = {", "\t\"com.google.keystone.agent\" => disabled", "\t\"com.apple.x\" => enabled", "\t\"old\" => true", "}",
        ])
        #expect(disabled == ["com.google.keystone.agent": true, "com.apple.x": false, "old": true])
        let list = StartupScanner.parseList(["PID\tStatus\tLabel", "954\t0\tcom.logi.optionsplus", "-\t0\tcom.google.keystone.agent"])
        #expect(list["com.logi.optionsplus"] == .some(954))
        #expect(list["com.google.keystone.agent"] == .some(nil))
    }

    @Test func parsesSfltool() {
        let lines = """
         Records for UID 0 : FFFF
         #1:
                         Name: root thing
                         Type: app (0x2)
                  Disposition: [enabled, allowed, notified] (0xb)
                   Identifier: 2.root
         Records for UID 501 : D043
         Items:

         #1:
                         Name: Raycast
               Developer Name: Raycast Technologies Inc
                         Type: app (0x2)
                  Disposition: [enabled, allowed, notified] (0xb)
                   Identifier: 2.com.raycast.macos
                          URL: /Applications/Raycast.app
          Embedded Item Identifiers:
            #1: 16.com.x

         #2:
                         Name: Docker
               Developer Name: Docker Inc
                         Type: app (0x2)
                  Disposition: [disabled, allowed, not notified] (0x2)
                   Identifier: 2.com.docker.docker
                          URL: /Applications/NoSuchDocker.app

         #3:
                         Name: DockerHelper
               Developer Name: (null)
                         Type: login item (0x4)
                  Disposition: [enabled, disallowed, notified] (0x9)
                   Identifier: 4.com.docker.helper
                          URL: Contents/Library/LoginItems/DockerHelper.app
            Parent Identifier: 2.com.docker.docker
        """.components(separatedBy: "\n")
        let records = BTMRecord.parse(lines, uid: 501)
        #expect(records.map(\.name) == ["Raycast", "Docker", "DockerHelper"])
        #expect(records[0].enabled && records[0].allowed)
        #expect(!records[1].enabled && records[1].allowed)
        #expect(records[2].enabled && !records[2].allowed)
        #expect(records[2].developer == nil)

        let items = StartupScanner().loginItems(records)
        // Docker (désactivé) n'est que le parent de son assistant.
        #expect(items.map(\.name) == ["Raycast", "Docker"])
        let helper = items[1]
        #expect(helper.detail == "Docker n’est plus installé")
        #expect(StartupScanner().loginItems([records[0]]).first?.detail == "Ouvre Raycast à la connexion")
        #expect(helper.orphan)
        #expect(!helper.enabled)
        #expect(!helper.canToggle)
    }

    @Test func cleansSignerName() {
        #expect(Signer.cleanName("Developer ID Application: Google LLC (EQHXZ8M8AV)") == "Google LLC")
        #expect(Signer.cleanName("Software Signing") == "Software Signing")
        #expect(Signer(name: nil, teamID: nil, apple: false, appStore: true, valid: true).label == "App Store · vérifié")
        let ls = Signer.of(path: "/bin/ls")
        #expect(ls?.apple == true)
        #expect(ls?.valid == true)
        #expect(Signer.of(path: "/nonexistent") == nil)
    }

    @Test func togglePlans() throws {
        let item = StartupItem(kind: .userAgent, label: "com.google.keystone.agent", name: "com.google.keystone.agent", detail: "",
                               url: URL(fileURLWithPath: "/Users/me/Library/LaunchAgents/com.google.keystone.agent.plist"),
                               executable: nil, enabled: true, running: false, impact: .low, signer: nil, orphan: false,
                               brewService: nil, parentApp: nil)
        let off = try #require(StartupScanner.togglePlan(item, enable: false))
        #expect(off.steps.map(\.displayString) == [
            "/bin/launchctl bootout gui/\(getuid())/com.google.keystone.agent",
            "/bin/launchctl disable gui/\(getuid())/com.google.keystone.agent",
        ])
        #expect(!off.stopOnFailure)
        let on = try #require(StartupScanner.togglePlan(item, enable: true))
        #expect(on.steps.last?.displayString == "/bin/launchctl bootstrap gui/\(getuid()) /Users/me/Library/LaunchAgents/com.google.keystone.agent.plist")
        var brew = item
        brew.brewService = "postgresql@16"
        #expect(StartupScanner.togglePlan(brew, enable: false) == nil)
        var orphan = item
        orphan.orphan = true
        let remove = try #require(StartupScanner.removePlan(orphan))
        #expect(remove.removals.count == 1)
        #expect(remove.reversible)
        var leftover = item
        leftover.leftover = true
        #expect(StartupScanner.removePlan(leftover)?.summary.contains("vide") == true)
        #expect(StartupScanner.togglePlan(leftover, enable: true) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LATELIER_LIVE"] == "1"))
    func liveSample() async {
        var system = SystemSampler()
        _ = system.sample()
        try? await Task.sleep(for: .seconds(1))
        let sample = system.sample()
        print("machine", system.machine, "cpu", sample.cpu, "perf", sample.performanceLoad, "eff", sample.efficiencyLoad)
        print("mem used", sample.memory.used >> 20, "app", sample.memory.app >> 20, "wired", sample.memory.wired >> 20,
              "compressed", sample.memory.compressed >> 20, "cached", sample.memory.cached >> 20, "swap", sample.memory.swapUsed >> 20, sample.memory.pressure)
        print("gpu", sample.gpu as Any, "net", sample.network, sample.networkIn, sample.networkOut, "disk", sample.diskRead, sample.diskWrite, sample.diskFree as Any)
        print("power", sample.power)

        var processes = ProcessSampler()
        _ = await processes.sample()
        try? await Task.sleep(for: .seconds(1))
        let start = Date()
        let list = await processes.sample()
        print("processes", list.count, "detailed", list.filter(\.detailed).count, "in", Date().timeIntervalSince(start))
        for p in list.sorted(by: { $0.cpu > $1.cpu }).prefix(8) {
            print(" ", p.pid, p.name, String(format: "%.1f%%", p.cpu), p.memory >> 20, "Mo", p.threads as Any, p.energy, p.isSystem ? "sys" : "", p.cwd ?? "")
        }
        let groups = ProcessGroup.group(list)
        print("groups", groups.count, groups.sorted { $0.memory > $1.memory }.prefix(5).map { "\($0.name) ×\($0.processes.count) \($0.memory >> 20) Mo" })

        let ports = await PortScanner().listening()
        print("ports", ports.map { "\($0.port) \($0.command) \($0.exposed ? "exposé" : "local")" })

        let paths = Set(list.compactMap(\.path))
        let startScan = Date()
        let startup = await StartupScanner().scan(runningPaths: paths)
        print("startup in", Date().timeIntervalSince(startScan), startup.problems)
        for item in startup.items {
            print(" ", item.kind, item.name, "|", item.detail, "|", item.enabled ? "on" : "off", item.running ? "running" : "", item.impact,
                  item.signer?.label ?? "-", item.orphan ? "ORPHELIN" : "", item.blockedInSettings ? "bloqué" : "")
        }
    }
}
