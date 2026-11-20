import Foundation
import Testing
@testable import LAtelierCore

@Suite("Moniteur SSH : lecture des mesures")
struct RemoteMonitorParserTests {
    func block(time: Int, cpu: String, cpu0: String, net: String, io: String, extra: [String] = []) -> [String] {
        ["@@T \(time)", "@@INFO", "srv", "Debian GNU/Linux 13 (trixie)", "6.12.0", "3600.5", "2", "deploy", "1000", "100", "nosudo",
         "@@STAT", cpu, cpu0, "@@LOAD", "0.50 0.40 0.30 1/200 999",
         "@@MEM", "MemTotal:       16000000 kB", "MemFree:         2000000 kB", "MemAvailable:    8000000 kB",
         "Buffers:          100000 kB", "Cached:          3000000 kB", "SReclaimable:     200000 kB",
         "SwapTotal:       2000000 kB", "SwapFree:        1500000 kB",
         "@@NET", "    lo: 999999 0 0 0 0 0 0 0 999999 0 0 0 0 0 0 0", net, "docker0: 5000 0 0 0 0 0 0 0 5000 0 0 0 0 0 0 0",
         "@@IO", io, "   8       1 sda1 10 0 99999 0 10 0 99999 0 0 0 0",
         "@@CPU", "4242 50",
         "@@PS", "   4242       1 www-data                  0.3  1.2 204800  3600 Sl   nginx: worker process",
         "      7       2 root                      0.0  0.0     0  9000 I    [kworker/0:1]"] + extra + ["@@END"]
    }

    @Test func computesRatesFromDeltas() throws {
        var parser = RemoteMonitorParser()
        var snapshots: [RemoteSnapshot] = []
        let first = block(time: 1000, cpu: "cpu  100 0 100 800 0 0 0 0", cpu0: "cpu0 100 0 100 800 0 0 0 0",
                          net: "  eth0: 1000 0 0 0 0 0 0 0 500 0 0 0 0 0 0 0", io: "   8       0 sda 10 0 1000 0 10 0 2000 0 0 0 0",
                          extra: ["@@DF", "/dev/sda1      ext4  1000000 900000 100000 90% /", "/dev/sdb1 ext4 2000000 100000 1900000 5% /mnt/data disk",
                                  "@@PORTS", #"LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=812,fd=3))"#, "LISTEN 0 511 127.0.0.1:5432 0.0.0.0:*",
                                  "@@SERVICES", "nginx.service loaded active running A high performance web server",
                                  "backup.service loaded failed failed Sauvegarde nocturne",
                                  "@@DOCKER", "abc123\tweb\tnginx:1.27\trunning\tUp 2 hours", "def456\tdb\tpostgres:17\texited\tExited (0) 3 days ago",
                                  "@@DSTATS", "abc123\t1.50%\t50MiB / 1GiB\t4.88%"])
        let second = block(time: 1002, cpu: "cpu  150 0 150 900 0 0 0 0", cpu0: "cpu0 150 0 150 900 0 0 0 0",
                           net: "  eth0: 3000 0 0 0 0 0 0 0 1500 0 0 0 0 0 0 0", io: "   8       0 sda 10 0 1400 0 10 0 2800 0 0 0 0")
        for line in first + second {
            if let snapshot = parser.feed(line) { snapshots.append(snapshot) }
        }
        #expect(snapshots.count == 2)
        #expect(snapshots[0].sample == nil)
        let sample = try #require(snapshots[1].sample)
        #expect(abs(sample.cpu - 50) < 0.01)          // 100 ticks actifs sur 200
        #expect(sample.cores.count == 1)
        #expect(sample.load == [0.5, 0.4, 0.3])
        #expect(sample.memoryTotal == 16_000_000 * 1024)
        #expect(sample.memoryUsed == 8_000_000 * 1024)
        #expect(sample.swapUsed == 500_000 * 1024)
        #expect(sample.networkIn == 1000)               // (3000 - 1000) / 2 s, lo et docker0 ignorés
        #expect(sample.networkOut == 500)
        #expect(sample.diskRead == 200 * 512)           // sda seulement, pas sda1
        #expect(sample.diskWrite == 400 * 512)

        let info = try #require(snapshots[0].info)
        #expect(info.os == "Debian GNU/Linux 13 (trixie)")
        #expect(info.login == "deploy")
        #expect(!info.canSudo)
        let nginx = try #require(snapshots[1].processes.first)
        #expect(nginx.name == "nginx")
        #expect(abs(nginx.cpu - 25) < 0.01)              // 50 ticks / (100 Hz × 2 s)
        #expect(nginx.started == 1002 - 3600)
        #expect(snapshots[1].processes.last?.isKernelThread == true)

        let first0 = snapshots[0]
        #expect(first0.disks?.map(\.mount) == ["/", "/mnt/data disk"])
        #expect(first0.ports?.map(\.port) == [22, 5432])
        #expect(first0.ports?.first?.process == "sshd")
        #expect(first0.ports?.last?.exposed == false)
        #expect(first0.services?.first?.name == "backup")
        #expect(first0.services?.first?.failed == true)
        #expect(first0.containers?.first?.cpu == 1.5)
        #expect(first0.containers?.last?.running == false)
        #expect(first0.dockerAvailability == .available)
        #expect(snapshots[1].disks == nil)
    }

    @Test func actionsCheckTheProcessFirst() {
        let process = RemoteProcess(pid: 42, ppid: 1, user: "deploy", cpu: 0, memoryPercent: 0, resident: 0, elapsed: 10,
                                    state: "S", command: "node app.js", started: 1_000_000)
        let command = RemoteActions.kill(process, force: false, sudo: false)
        #expect(command.contains("ps -o etimes= -p 42"))
        #expect(command.contains("- 1000000"))
        #expect(command.hasSuffix("kill -TERM 42"))
        #expect(RemoteActions.kill(process, force: true, sudo: true).hasSuffix("sudo -n kill -KILL 42"))
        #expect(RemoteActions.service("nginx", .restart, sudo: true) == "sudo -n systemctl restart -- nginx.service")
        #expect(RemoteActions.container("web app", .stop, sudo: false) == "docker stop 'web app'")
    }
}

/// Sur un vrai serveur (LATELIER_SSH_LIVE=<alias>) : 9 s de mesures, en lecture seule.
@Suite("Moniteur SSH : serveur réel", .enabled(if: ProcessInfo.processInfo.environment["LATELIER_SSH_LIVE"] != nil))
struct RemoteMonitorLiveTests {
    @Test func streamsSnapshots() async throws {
        let alias = ProcessInfo.processInfo.environment["LATELIER_SSH_LIVE"]!
        SSHCommands.prepareControlDirectory()
        let spec = SSHCommands(alias: alias).ssh(RemoteMonitorScript.remoteCommand)
        let task = Task { () -> [RemoteSnapshot] in
            var parser = RemoteMonitorParser()
            var snapshots: [RemoteSnapshot] = []
            do {
                for try await event in CommandRunner().stream(spec) {
                    if case .stdout(let line) = event, let snapshot = parser.feed(line) { snapshots.append(snapshot) }
                    if case .stderr(let line) = event { print("stderr: \(line)") }
                }
            } catch {}
            return snapshots
        }
        try await Task.sleep(for: .seconds(9))
        task.cancel()
        let snapshots = await task.value
        #expect(snapshots.count >= 3)
        let sample = try #require(snapshots.last?.sample)
        print("CPU \(sample.cpu) % · cœurs \(sample.cores.count) · mémoire \(sample.memoryUsed / 1_048_576) / \(sample.memoryTotal / 1_048_576) Mo · réseau ↓\(Int(sample.networkIn)) ↑\(Int(sample.networkOut)) o/s · disque ↓\(Int(sample.diskRead)) ↑\(Int(sample.diskWrite)) o/s")
        for process in snapshots.last!.processes.prefix(5) { print(String(format: "%7d %-10@ %5.1f %% %@", process.pid, process.user, process.cpu, process.command)) }
        let first = snapshots[0]
        print("info: \(String(describing: first.info))")
        print("disques: \(first.disks?.map { "\($0.mount) \(Int($0.fraction * 100)) %" } ?? [])")
        print("ports: \(first.ports?.map { "\($0.port)/\($0.process ?? "?")" } ?? []) · services: \(first.services?.count ?? -1) (\(first.services?.filter(\.failed).map(\.name) ?? [])) · conteneurs: \(first.containers?.count ?? -1) docker \(String(describing: first.dockerAvailability))")
        #expect(!(snapshots.last?.processes.isEmpty ?? true))
    }
}

/// Sur un vrai serveur : un `sleep` jetable, que l'action refuse d'arrêter si la date de lancement
/// ne correspond pas, puis arrête quand c'est bien lui.
@Suite("Moniteur SSH : arrêt d'un processus réel", .enabled(if: ProcessInfo.processInfo.environment["LATELIER_SSH_LIVE"] != nil))
struct RemoteKillLiveTests {
    @Test func killsOnlyTheSameProcess() async throws {
        let alias = ProcessInfo.processInfo.environment["LATELIER_SSH_LIVE"]!
        let ssh = SSHCommands(alias: alias)
        let runner = CommandRunner()
        let start = try await runner.run(ssh.ssh("nohup sleep 600 >/dev/null 2>&1 & echo $!; sleep 1"), timeout: .seconds(20))
        let pid = try #require(start.stdout.first.flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) })
        let probe = try await runner.run(ssh.ssh("echo $(date +%s) $(ps -o etimes= -p \(pid))"), timeout: .seconds(20))
        let parts = try #require(probe.stdout.first).split(separator: " ").compactMap { Int($0) }
        let started = parts[0] - parts[1]
        func process(_ start: Int) -> RemoteProcess {
            RemoteProcess(pid: pid, ppid: 1, user: "", cpu: 0, memoryPercent: 0, resident: 0, elapsed: 0, state: "S", command: "sleep 600", started: start)
        }
        let wrong = try await runner.run(ssh.ssh(RemoteActions.kill(process(started - 100), force: false, sudo: false)), timeout: .seconds(20))
        #expect(!wrong.succeeded)
        #expect(wrong.stderr.joined().contains("autre processus"))
        let alive = try await runner.run(ssh.ssh("kill -0 \(pid)"), timeout: .seconds(20))
        #expect(alive.succeeded)
        let right = try await runner.run(ssh.ssh(RemoteActions.kill(process(started), force: false, sudo: false)), timeout: .seconds(20))
        #expect(right.succeeded)
        try await Task.sleep(for: .seconds(1))
        let gone = try await runner.run(ssh.ssh("kill -0 \(pid) 2>/dev/null"), timeout: .seconds(20))
        #expect(!gone.succeeded)
        _ = try? await runner.run(ssh.ssh("kill \(pid) 2>/dev/null; true"), timeout: .seconds(20))
    }
}
