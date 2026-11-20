import AppKit
import LAtelierCore
import Observation
import Security

/// Mises à jour de L’Atelier depuis le dépôt GitHub public (Releases).
/// Installation par l'image disque publiée, ou depuis les sources si l'app a été installée par install.sh.
@Observable
final class UpdateStore {
    enum State: Equatable {
        case idle, checking, upToDate, available(AppRelease), failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastCheck: Date?
    @ObservationIgnored private var preview: (ActionPlan) -> Void = { _ in }
    @ObservationIgnored private var preferences: ToolPreferences?
    @ObservationIgnored private var timer: Timer?
    private static let lastCheckKey = "appUpdateLastCheck"
    static let planPrefix = "Mettre à jour L’Atelier"

    /// `propriétaire/dépôt`, écrit dans l'Info.plist à la compilation.
    let repository = Bundle.main.object(forInfoDictionaryKey: "LAtelierRepository") as? String
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    /// Dossier des sources quand l'app a été installée par install.sh.
    let sourcePath = (Bundle.main.object(forInfoDictionaryKey: "LAtelierSourcePath") as? String).map { URL(fileURLWithPath: $0) }

    var available: AppRelease? {
        if case .available(let release) = state { return release }
        return nil
    }

    var installedFromSource: Bool {
        guard let sourcePath else { return false }
        return FileManager.default.fileExists(atPath: sourcePath.appendingPathComponent(".git").path)
    }

    init() {
        lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
    }

    func attach(preferences: ToolPreferences, preview: @escaping (ActionPlan) -> Void) {
        self.preferences = preferences
        self.preview = preview
        // Une fois par jour au plus, si le réglage le permet.
        timer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard preferences?.checkAppUpdates == true, repository != nil else { return }
        if let lastCheck, Date.now.timeIntervalSince(lastCheck) < 86_400 { return }
        check()
    }

    func check() {
        guard let repository, let url = UpdateChecker.latestURL(repository: repository) else {
            state = .failed("Dépôt GitHub inconnu : cette version a été compilée sans dépôt (GITHUB_REPO).")
            return
        }
        state = .checking
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LAtelier", forHTTPHeaderField: "User-Agent")
        let current = currentVersion
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                lastCheck = .now
                UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)
                if status == 404 {
                    state = .upToDate // aucune version publiée pour l'instant
                    return
                }
                guard status == 200, let release = UpdateChecker.parse(data) else {
                    state = .failed("Réponse inattendue de GitHub (code \(status)).")
                    return
                }
                state = UpdateChecker.isNewer(release.version, than: current) ? .available(release) : .upToDate
            } catch {
                state = .failed("GitHub injoignable : \(error.localizedDescription)")
            }
        }
    }

    // MARK: Installation (toujours avec aperçu)

    func install(_ release: AppRelease) {
        let installed = Bundle.main.bundleURL
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("latelier-update-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        if installedFromSource, let source = sourcePath {
            present(ActionPlan(
                title: "\(Self.planPrefix) \(release.version)",
                summary: "Depuis les sources (\(source.abbreviatingHome())) : récupère le tag \(release.tag), compile sur ce Mac, remplace l’app. L’ancienne version va à la corbeille ; L’Atelier redémarre ensuite.",
                kind: .paquet, risk: .caution, reversible: true,
                steps: UpdatePlanner.fromSource(release, source: source, installed: installed, work: work)
            ))
            return
        }
        guard let dmg = release.dmg, let checksumURL = release.checksum else {
            state = .failed("La version \(release.version) ne contient pas d’image disque avec son empreinte (.dmg et .dmg.sha256).")
            return
        }
        Task {
            do {
                var request = URLRequest(url: checksumURL, timeoutInterval: 20)
                request.setValue("LAtelier", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let sha = UpdateChecker.checksum(in: String(decoding: data, as: UTF8.self)) else {
                    state = .failed("Empreinte SHA-256 illisible dans \(checksumURL.lastPathComponent).")
                    return
                }
                let requirement = Self.designatedRequirement()
                var summary = "Télécharge \(dmg.lastPathComponent), vérifie son empreinte SHA-256"
                summary += requirement != nil ? " et que l’app est signée par le même certificat que celle-ci" : " (signature ad hoc : le certificat ne peut pas être comparé)"
                summary += ", puis remplace \(installed.abbreviatingHome()). L’ancienne version va à la corbeille ; L’Atelier redémarre ensuite."
                present(ActionPlan(
                    title: "\(Self.planPrefix) \(release.version)", summary: summary,
                    kind: .paquet, risk: .caution, reversible: true,
                    steps: UpdatePlanner.fromRelease(release, dmg: dmg, sha256: sha, installed: installed, requirement: requirement, work: work)
                ))
            } catch {
                state = .failed("Téléchargement de l’empreinte impossible : \(error.localizedDescription)")
            }
        }
    }

    private func present(_ plan: ActionPlan) {
        var plan = plan
        plan.allowsPermanent = false
        plan.stopOnFailure = true
        preview(plan)
    }

    /// Après la mise à jour réussie : relance la nouvelle version.
    func didRecord(_ entry: HistoryEntry) {
        guard entry.title.hasPrefix(Self.planPrefix), entry.outcome == .success else { return }
        let path = Bundle.main.bundleURL.path
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1.5; /usr/bin/open \(ShellQuote.quote(path))"]
        try? relaunch.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }

    /// Exigence de signature de l'app en cours (certificat stable) ; nil si signée ad hoc.
    static func designatedRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        let string = text as String
        return string.contains("cdhash") ? nil : string
    }
}
