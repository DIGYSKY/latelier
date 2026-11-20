import AppKit
import LAtelierCore
import ServiceManagement

/// Signaler un problème, informations de diagnostic, désinstallation propre.
extension AppModel {
    var repository: String { updates.repository ?? "DIGYSKY/latelier" }

    var issueEnvironment: IssueReport.Environment {
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var arch = "Apple silicon"
        #if arch(x86_64)
        arch = "Intel"
        #endif
        let installation: String
        if updates.installedFromSource {
            installation = "install.sh"
        } else if Bundle.main.bundleURL.path.hasPrefix("/Applications/") || Bundle.main.bundleURL.path.hasPrefix(NSHomeDirectory() + "/Applications/") {
            installation = String(localized: "image disque (.dmg)")
        } else {
            installation = String(localized: "compilée depuis un clone")
        }
        return IssueReport.Environment(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "dev",
            build: info?["CFBundleVersion"] as? String ?? "?",
            macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            architecture: arch, installation: installation,
            language: Locale.current.language.languageCode?.identifier ?? "?"
        )
    }

    /// Ouvre la page GitHub de l'issue, pré-remplie. `details` (sortie d'erreur) est expurgé du chemin personnel.
    func reportIssue(_ kind: IssueReport.Kind = .bug, details: String? = nil) {
        let cleaned = details.map { IssueReport.redact($0) }
        if let url = IssueReport.url(repository: repository, kind: kind, environment: issueEnvironment, details: cleaned) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Relance L’Atelier (changement de langue).
    func relaunch() {
        let path = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \(ShellQuote.quote(path))"]
        try? process.run()
        NSApp.terminate(nil)
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(issueEnvironment.summary, forType: .string)
    }

    /// Ce que L’Atelier a écrit sur ce Mac (pour « Désinstaller proprement »).
    var ownData: [(label: String, url: URL)] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let candidates: [(String, URL)] = [
            (String(localized: "Historique, réglages internes, enregistrements"), AppPaths.supportDirectory),
            (String(localized: "Caches (versions, failles, scripts)"), AppPaths.cacheDirectory),
            ("Préférences", home.appendingPathComponent("Library/Preferences/\(AppPaths.bundleIdentifier).plist")),
            ("Sources (installation par install.sh)", home.appendingPathComponent(".latelier")),
            ("Connexions SSH partagées", URL(fileURLWithPath: SSHCommands.defaultControlDirectory)),
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.1.path) }
    }

    /// Désinstallation : données de l'app puis l'app elle-même, à la corbeille, avec aperçu.
    /// ~/.ssh/config, l'historique git de vos projets et le certificat de signature ne sont pas touchés.
    func uninstallPlan() -> ActionPlan {
        let home = NSHomeDirectory()
        var steps: [ActionStep] = ownData.filter { $0.url.path.hasPrefix(home + "/") }
            .map { .remove($0.url, bytes: DiskUsage.measure($0.url).bytes, permanently: false) }
        let app = Bundle.main.bundleURL
        if SafetyGuard.isApplicationBundle(app.path) {
            steps.append(.remove(app, bytes: DiskUsage.measure(app).bytes, permanently: false))
        }
        var plan = ActionPlan(
            title: String(localized: "Désinstaller L’Atelier"),
            summary: String(localized: "Tout va à la corbeille : vous pouvez encore revenir en arrière. Votre ~/.ssh/config, vos projets et vos serveurs ne sont pas touchés. L’Atelier se ferme ensuite."),
            kind: .systeme, risk: .caution, reversible: true, steps: steps
        )
        plan.allowsPermanent = false
        return plan
    }

    /// Après la désinstallation : retirer l'ouverture à la connexion et quitter.
    func finishUninstall(_ entry: HistoryEntry) {
        guard entry.title == String(localized: "Désinstaller L’Atelier"), entry.outcome == .success else { return }
        try? SMAppService.mainApp.unregister()
        // L'entrée d'historique vient de recréer le dossier de données : il repart à la corbeille.
        try? FileManager.default.trashItem(at: AppPaths.supportDirectory, resultingItemURL: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }
}
