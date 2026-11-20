import Foundation
import LAtelierCore
import UserNotifications

/// Notifications macOS (seulement celles activées dans Réglages › Notifications).
enum Notifier {
    static func send(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }
}

extension AppModel {
    /// Tâches de fond : vérifications périodiques, fetch automatique, espace disque, processus gourmands.
    /// Une minute entre deux passages ; rien de lourd sur batterie si le réglage le demande.
    func startBackgroundChecks() {
        Task { [weak self] in
            try? await self?.historyStore.prune(olderThan: self?.preferences.historyDays ?? 90)
            await self?.reloadHistory()
            var sampler = ProcessSampler(runner: self?.runner ?? CommandRunner())
            var heavy: [Int32: Int] = [:]
            var notifiedHeavy: Set<String> = []
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                let paused = preferences.pauseOnBattery && PowerSnapshot.current().onBattery
                if !paused { runDueChecks() }
                if tick % 15 == 0 { checkDiskSpace() }
                if preferences.notifyHeavyProcess {
                    let processes = await sampler.sample()
                    let me = getuid()
                    var next: [Int32: Int] = [:]
                    for process in processes where process.uid == me && process.cpu >= 80 {
                        next[process.pid] = (heavy[process.pid] ?? 0) + 1
                        let key = "\(process.pid)-\(process.started)"
                        if next[process.pid]! >= 5, !notifiedHeavy.contains(key) {
                            notifiedHeavy.insert(key)
                            Notifier.send(id: "heavy-\(key)", title: String(localized: "Processus gourmand"),
                                          body: String(localized: "\(process.displayName) utilise \(Int(process.cpu)) % de CPU depuis 5 minutes."))
                        }
                    }
                    heavy = next
                }
                tick += 1
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func due(_ key: String, every interval: TimeInterval) -> Bool {
        let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= interval else { return false }
        UserDefaults.standard.set(Date(), forKey: key)
        return true
    }

    private func runDueChecks() {
        let interval: TimeInterval? = switch preferences.checkInterval {
        case "hourly": 3600
        case "daily": 86_400
        default: nil
        }
        if let interval, due("lastBackgroundCheck", every: interval) {
            ensureRepos()
            if !packages.scanning { scanPackages() }
            if !analysis.loading { scanAnalysis() }
        }
        if preferences.autoFetch, !repos.repos.isEmpty, due("lastAutoFetch", every: 3600) {
            fetchAll()
        }
    }

    /// Moins de 10 % d'espace libre : une notification par jour au plus.
    private func checkDiskSpace() {
        guard preferences.notifyLowSpace,
              let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, total > 0,
              let free = values.volumeAvailableCapacityForImportantUsage else { return }
        guard Double(free) / Double(total) < 0.10, due("lastLowSpaceNotice", every: 86_400) else { return }
        Notifier.send(id: "low-space", title: String(localized: "Espace disque faible"),
                      body: String(localized: "Plus que \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) libres. Stockage › Vue d’ensemble montre ce qui est récupérable."))
    }
}
