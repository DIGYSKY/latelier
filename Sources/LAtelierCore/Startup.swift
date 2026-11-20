import Foundation
import Security

/// Ce qui se lance à l'ouverture de session ou au démarrage du Mac.
public struct StartupItem: Sendable, Identifiable, Hashable {
    public enum Kind: Int, Sendable, CaseIterable {
        /// Réglages Système › Général › Ouverture : apps et assistants déclarés par les apps.
        case loginItem
        /// `~/Library/LaunchAgents`.
        case userAgent
        /// `/Library/LaunchAgents` et `/Library/LaunchDaemons` : admin requis.
        case systemAgent

        public var title: String {
            switch self {
            case .loginItem: String(localized: "Éléments de connexion")
            case .userAgent: String(localized: "Agents utilisateur")
            case .systemAgent: String(localized: "Agents et démons système")
            }
        }

        public var location: String {
            switch self {
            case .loginItem: String(localized: "Réglages Système › Général › Ouverture")
            case .userAgent: "~/Library/LaunchAgents"
            case .systemAgent: "/Library/LaunchAgents · /Library/LaunchDaemons"
            }
        }
    }

    public enum Impact: Int, Sendable, Comparable {
        case low, medium, high

        public var label: String {
            switch self {
            case .low: "faible"
            case .medium: "moyen"
            case .high: String(localized: "élevé")
            }
        }

        /// Secondes ajoutées à l'ouverture de session (ordre de grandeur, pour le résumé).
        public var seconds: Double {
            switch self {
            case .low: 0.4
            case .medium: 1.5
            case .high: 3
            }
        }

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public var kind: Kind
    /// Label launchd, ou identifiant de l'app.
    public var label: String
    public var name: String
    public var detail: String
    /// Fichier plist (agents) ou app (éléments de connexion).
    public var url: URL?
    public var executable: String?
    public var enabled: Bool
    public var running: Bool
    public var impact: Impact
    public var signer: Signer?
    /// L'exécutable n'existe plus (app supprimée).
    public var orphan: Bool
    /// Géré par `brew services` : on renvoie vers Paquets › Services.
    public var brewService: String?
    /// Application à laquelle l'élément appartient.
    public var parentApp: String?
    /// Interdit dans Réglages Système › Général › Ouverture (« Autoriser en arrière-plan »).
    public var blockedInSettings = false
    /// Fichier vide ou sans `Label` : launchd l'ignore, c'est un reste.
    public var leftover = false

    public var id: String { "\(kind.rawValue):\(label):\(url?.path ?? "")" }

    /// Modifiable d'ici : agents utilisateur seulement (les autres demandent les Réglages ou un admin).
    public var canToggle: Bool { kind == .userAgent && brewService == nil && !orphan && !leftover && !blockedInSettings }
    public var canRemove: Bool { kind == .userAgent && (orphan || leftover) && url != nil }
}

/// Signature de code de l'exécutable.
public struct Signer: Sendable, Hashable {
    public var name: String?
    public var teamID: String?
    public var apple: Bool
    /// App du Mac App Store (signée par Apple pour le compte de l'éditeur).
    public var appStore = false
    /// Signature valide (contrôle rapide, sans vérifier toutes les ressources).
    public var valid: Bool

    public var label: String {
        guard valid || name != nil || appStore else { return String(localized: "Non signé") }
        let who = apple ? "Apple" : appStore ? (name ?? "App Store") : name ?? String(localized: "Signature ad hoc")
        return valid ? String(localized: "\(who) · vérifié") : String(localized: "\(who) · signature invalide")
    }

    public static func of(path: String) -> Signer? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return Signer(name: nil, teamID: nil, apple: false, valid: false) }
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSBasicValidateOnly)
        let valid = SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
        let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let summary = certificates.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let apple = summary.map { $0.hasSuffix("Software Signing") } ?? false
        let appStore = summary.map { $0.hasPrefix("Apple Mac OS Application Signing") } ?? false
        guard certificates.first != nil else { return Signer(name: nil, teamID: team, apple: false, valid: false) }
        return Signer(name: appStore ? nil : summary.map(cleanName), teamID: team, apple: apple, appStore: appStore, valid: valid)
    }

    /// « Developer ID Application: Google LLC (EQHXZ8M8AV) » → « Google LLC ».
    static func cleanName(_ summary: String) -> String {
        var name = summary
        for prefix in ["Developer ID Application: ", "Apple Development: ", "Apple Distribution: ", "Mac Developer: ", "3rd Party Mac Developer Application: "]
        where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        if let open = name.range(of: " (", options: .backwards), name.hasSuffix(")") {
            name = String(name[..<open.lowerBound])
        }
        return name
    }
}

/// Une plist launchd réduite à ce qui nous sert.
public struct LaunchPlist: Sendable, Equatable {
    public var label: String
    public var program: String?
    public var runAtLoad: Bool
    public var keepAlive: Bool
    public var periodic: Bool
    public var disabledKey: Bool

    public static func parse(_ data: Data) -> LaunchPlist? {
        guard let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = dict["Label"] as? String else { return nil }
        let program = dict["Program"] as? String ?? (dict["ProgramArguments"] as? [String])?.first
        let keepAlive: Bool = {
            if let flag = dict["KeepAlive"] as? Bool { return flag }
            return dict["KeepAlive"] is [String: Any]
        }()
        return LaunchPlist(
            label: label, program: program, runAtLoad: dict["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive,
            periodic: dict["StartInterval"] != nil || dict["StartCalendarInterval"] != nil || dict["WatchPaths"] != nil,
            disabledKey: dict["Disabled"] as? Bool ?? false
        )
    }

    public var impact: StartupItem.Impact {
        if keepAlive && runAtLoad { return .high }
        if runAtLoad || keepAlive { return .medium }
        return .low
    }

    /// L'exécutable a disparu (seulement pour un chemin absolu : `/usr/bin/env` etc. sont présents).
    public var orphan: Bool {
        guard let program, program.hasPrefix("/") else { return false }
        return !FileManager.default.fileExists(atPath: program)
    }
}

/// Un enregistrement de `sfltool dumpbtm` (Background Task Management).
public struct BTMRecord: Sendable, Equatable {
    public var name: String
    public var developer: String?
    public var type: String
    public var disposition: String
    public var identifier: String
    public var url: String?
    public var executable: String?
    public var bundleID: String?
    public var parent: String?

    public var enabled: Bool { disposition.contains("[enabled") }
    public var allowed: Bool { disposition.contains(" allowed") }

    /// Sortie de `sfltool dumpbtm`, limitée à la section de l'utilisateur.
    public static func parse(_ lines: [String], uid: UInt32) -> [BTMRecord] {
        var inUser = false
        var records: [BTMRecord] = []
        var current: [String: String] = [:]
        func flush() {
            if let type = current["Type"], let identifier = current["Identifier"] {
                let value = { (key: String) -> String? in
                    guard let v = current[key], v != "(null)" else { return nil }
                    return v
                }
                records.append(BTMRecord(
                    name: value("Name") ?? identifier, developer: value("Developer Name"), type: type,
                    disposition: current["Disposition"] ?? "", identifier: identifier, url: value("URL"),
                    executable: value("Executable Path"), bundleID: value("Bundle Identifier"), parent: value("Parent Identifier")
                ))
            }
            current = [:]
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID") {
                flush()
                let uidText = line.dropFirst("Records for UID".count).split(separator: ":").first?.trimmingCharacters(in: .whitespaces)
                inUser = uidText == String(uid)
                continue
            }
            guard inUser else { continue }
            if line.hasPrefix("#") && line.hasSuffix(":") { flush(); continue }
            guard let colon = line.range(of: ": ") else { continue }
            let key = String(line[..<colon.lowerBound])
            if current[key] == nil { current[key] = String(line[colon.upperBound...]) }
        }
        flush()
        return records
    }
}

public struct StartupScanner: Sendable {
    public let runner: CommandRunner
    public let home: URL

    public init(runner: CommandRunner = CommandRunner(), home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.runner = runner
        self.home = home
    }

    public struct Result: Sendable {
        public var items: [StartupItem]
        public var problems: [String]
    }

    /// `runningPaths` : chemins des exécutables en cours (liste des processus).
    public func scan(runningPaths: Set<String>) async -> Result {
        let uid = getuid()
        async let btm = runner.run(CommandSpec("/usr/bin/sfltool", ["dumpbtm"]), timeout: .seconds(20))
        async let disabled = runner.run(CommandSpec("/bin/launchctl", ["print-disabled", "gui/\(uid)"]), timeout: .seconds(5))
        async let loaded = runner.run(CommandSpec("/bin/launchctl", ["list"]), timeout: .seconds(5))

        var problems: [String] = []
        let disabledLabels = Self.parseDisabled((try? await disabled)?.stdout ?? [])
        let loadedList = Self.parseList((try? await loaded)?.stdout ?? [])
        let records: [BTMRecord]
        if let output = try? await btm, output.exitStatus == 0 {
            records = BTMRecord.parse(output.stdout, uid: uid)
        } else {
            records = []
            problems.append(String(localized: "Éléments de connexion illisibles (sfltool)."))
        }

        var items: [StartupItem] = []
        items += loginItems(records)
        // Agents « legacy » : identifiant BTM = « 8.<label> » (agent) ou « 16.<label> » (démon).
        var btmByLabel: [String: BTMRecord] = [:]
        for record in records where record.type.hasPrefix("legacy") {
            if let dot = record.identifier.firstIndex(of: ".") { btmByLabel[String(record.identifier[record.identifier.index(after: dot)...])] = record }
        }

        let userDir = home.appendingPathComponent("Library/LaunchAgents")
        for url in Self.plists(in: userDir) {
            guard let data = try? Data(contentsOf: url), let plist = LaunchPlist.parse(data) else {
                let label = url.deletingPathExtension().lastPathComponent
                items.append(StartupItem(
                    kind: .userAgent, label: label, name: label, detail: String(localized: "Fichier vide ou illisible : launchd l’ignore"),
                    url: url, executable: nil, enabled: false, running: false, impact: .low, signer: nil, orphan: false,
                    brewService: nil, parentApp: nil, leftover: true
                ))
                continue
            }
            let blocked = btmByLabel[plist.label].map { !$0.allowed } ?? false
            let enabled = !(disabledLabels[plist.label] ?? plist.disabledKey) && !blocked
            let pid = loadedList[plist.label] ?? nil
            let running = pid != nil || plist.program.map(runningPaths.contains) == true
            let brew = plist.label.hasPrefix("homebrew.mxcl.") ? String(plist.label.dropFirst("homebrew.mxcl.".count)) : nil
            items.append(StartupItem(
                kind: .userAgent, label: plist.label, name: plist.label,
                detail: brew != nil ? String(localized: "brew services · voir Paquets › Services") : Self.describe(plist, orphan: plist.orphan),
                url: url, executable: plist.program, enabled: enabled, running: running, impact: plist.impact,
                signer: plist.program.flatMap(Signer.of), orphan: plist.orphan, brewService: brew,
                parentApp: Self.appName(plist.program), blockedInSettings: blocked
            ))
        }

        for dir in ["/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            for url in Self.plists(in: URL(fileURLWithPath: dir)) {
                guard let data = try? Data(contentsOf: url), let plist = LaunchPlist.parse(data) else { continue }
                let record = btmByLabel[plist.label]
                let running = plist.program.map(runningPaths.contains) == true
                items.append(StartupItem(
                    kind: .systemAgent, label: plist.label, name: plist.label,
                    detail: Self.describe(plist, orphan: plist.orphan) + (dir.hasSuffix("Daemons") ? " · démon" : ""),
                    url: url, executable: plist.program,
                    enabled: record.map { $0.enabled && $0.allowed } ?? !plist.disabledKey,
                    running: running, impact: plist.impact, signer: plist.program.flatMap(Signer.of), orphan: plist.orphan,
                    brewService: nil, parentApp: Self.appName(plist.program),
                    blockedInSettings: record.map { !$0.allowed } ?? false
                ))
            }
        }
        return Result(items: items, problems: problems)
    }

    /// Apps ouvertes à la connexion, assistants (`SMAppService`) et agents déclarés par des apps.
    func loginItems(_ records: [BTMRecord]) -> [StartupItem] {
        let byIdentifier = Dictionary(records.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        var items: [StartupItem] = []
        for record in records {
            let type = record.type
            let isApp = type.hasPrefix("app ")
            let isHelper = type.hasPrefix("login item") || type.hasPrefix("agent ")
            // Une app n'est un élément de connexion que si elle est activée (sinon c'est juste le parent d'un assistant).
            guard (isApp && record.enabled) || isHelper else { continue }
            let parent = record.parent.flatMap { byIdentifier[$0] }
            let appPath = isApp ? record.url : parent?.url
            let appExists = appPath.map { FileManager.default.fileExists(atPath: $0) } ?? true
            let appName = isApp ? record.name : parent?.name
            let developer = record.developer ?? parent?.developer
            let detail: String
            if isApp {
                detail = String(localized: "Ouvre \(record.name) à la connexion")
            } else if let appName {
                detail = String(localized: "Assistant en arrière-plan de l’app")
            } else {
                detail = record.name
            }
            var signer = appPath.flatMap(Signer.of)
            if signer?.appStore == true { signer?.name = developer }
            if signer == nil, let developer { signer = Signer(name: developer, teamID: nil, apple: false, valid: true) }
            items.append(StartupItem(
                kind: .loginItem, label: record.bundleID ?? record.identifier, name: isApp ? record.name : (appName ?? record.name),
                detail: appExists ? detail : String(localized: "\(appName ?? record.name) n’est plus installé"),
                url: appPath.map { URL(fileURLWithPath: $0) }, executable: record.executable,
                enabled: record.enabled && record.allowed, running: false, impact: isApp ? .medium : .low,
                signer: signer, orphan: !appExists, brewService: nil, parentApp: appName
            ))
        }
        return items
    }

    static func plists(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "plist" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func describe(_ plist: LaunchPlist, orphan: Bool) -> String {
        if orphan, let program = plist.program {
            return String(localized: "\(appName(program) ?? (program as NSString).lastPathComponent) n’est plus installé")
        }
        var parts: [String] = []
        if plist.keepAlive { parts.append(String(localized: "toujours actif")) } else if plist.runAtLoad { parts.append(String(localized: "à l’ouverture de session")) }
        if plist.periodic { parts.append(String(localized: "périodique")) }
        if parts.isEmpty { parts.append(String(localized: "à la demande")) }
        return parts.joined(separator: " · ")
    }

    /// « /Applications/Zoom.app/Contents/… » → « Zoom ».
    static func appName(_ path: String?) -> String? {
        guard let path, let range = path.range(of: ".app/") ?? path.range(of: ".app", options: .backwards) else { return nil }
        return (String(path[..<range.lowerBound]) as NSString).lastPathComponent
    }

    /// `"com.example.agent" => disabled` (ou `=> true` sur les anciens systèmes).
    static func parseDisabled(_ lines: [String]) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in lines {
            guard let arrow = line.range(of: "=>") else { continue }
            let label = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            result[label] = value == "disabled" || value == "true"
        }
        return result
    }

    /// `launchctl list` : `PID  Status  Label`.
    static func parseList(_ lines: [String]) -> [String: Int32?] {
        var result: [String: Int32?] = [:]
        for line in lines.dropFirst() {
            let fields = line.split(separator: "\t")
            guard fields.count >= 3 else { continue }
            result[String(fields[2])] = Int32(fields[0])
        }
        return result
    }

    // MARK: Actions (agents utilisateur)

    public static func togglePlan(_ item: StartupItem, enable: Bool) -> ActionPlan? {
        guard item.canToggle, let url = item.url else { return nil }
        let domain = "gui/\(getuid())"
        let steps: [CommandSpec] = enable
            ? [CommandSpec("/bin/launchctl", ["enable", "\(domain)/\(item.label)"]),
               CommandSpec("/bin/launchctl", ["bootstrap", domain, url.path])]
            : [CommandSpec("/bin/launchctl", ["bootout", "\(domain)/\(item.label)"]),
               CommandSpec("/bin/launchctl", ["disable", "\(domain)/\(item.label)"])]
        return ActionPlan(
            title: enable ? String(localized: "Réactiver \(item.label)") : String(localized: "Désactiver \(item.label)"),
            summary: enable
                ? String(localized: "L’agent sera de nouveau lancé à l’ouverture de session, et démarré tout de suite.")
                : String(localized: "L’agent est arrêté et ne sera plus lancé à l’ouverture de session. Le fichier reste en place : on peut le réactiver d’ici."),
            kind: .systeme, risk: .caution, reversible: true,
            // bootout échoue si l'agent n'était pas chargé : ce n'est pas bloquant.
            steps: steps.map(ActionStep.command), stopOnFailure: false
        )
    }

    public static func removePlan(_ item: StartupItem) -> ActionPlan? {
        guard item.canRemove, let url = item.url else { return nil }
        var steps: [ActionStep] = []
        if item.running || item.enabled {
            steps.append(.command(CommandSpec("/bin/launchctl", ["bootout", "gui/\(getuid())/\(item.label)"])))
        }
        let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        steps.append(.remove(url, bytes: bytes, permanently: false))
        return ActionPlan(
            title: String(localized: "Supprimer l’agent \(item.label)"),
            summary: item.leftover
                ? String(localized: "Ce fichier est vide : il ne lance rien. Il part à la corbeille.")
                : "\(item.detail). Le fichier de l’agent part à la corbeille.",
            kind: .systeme, risk: .safe, reversible: true, steps: steps, estimatedBytes: bytes, stopOnFailure: false
        )
    }
}
