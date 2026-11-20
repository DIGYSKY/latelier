import CoreServices
import Foundation

// MARK: - Apps installées

public struct InstalledApp: Sendable, Identifiable, Hashable {
    public var url: URL
    public var name: String
    public var bundleID: String?
    public var version: String?
    public var lastUsed: Date?
    /// Installée par le Mac App Store (reçu dans le paquet).
    public var fromAppStore: Bool
    /// Fournie par Apple avec macOS (dans /System) : jamais désinstallable.
    public var isSystem: Bool
    /// L'utilisateur peut la mettre à la corbeille sans mot de passe.
    public var deletable: Bool
    /// Taille du paquet .app (mesurée après coup).
    public var bytes: Int64?

    public var id: String { url.path }
}

public enum AppInventory {
    public static func roots(home: String = NSHomeDirectory()) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: home).appending(path: "Applications")]
    }

    /// Apps du Désinstalleur : directement dans /Applications ou ~/Applications.
    public static func installed(roots: [URL] = roots()) -> [InstalledApp] {
        roots.flatMap { root in
            ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "app" }
                .compactMap { read($0) }
        }
        .filter { !$0.isSystem }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Tous les identifiants d'apps présents (y compris Utilities, /System/Applications et un niveau de sous-dossiers),
    /// pour ne jamais prendre pour un reste les données d'une app installée.
    public static func allBundleIDs(home: String = NSHomeDirectory()) -> Set<String> {
        var ids: Set<String> = []
        let fm = FileManager.default
        let bases = roots(home: home) + [URL(fileURLWithPath: "/System/Applications"), URL(fileURLWithPath: "/Applications/Utilities"),
                                         URL(fileURLWithPath: "/System/Applications/Utilities")]
        for base in bases {
            for child in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
                if child.pathExtension == "app" {
                    if let id = Bundle(url: child)?.bundleIdentifier { ids.insert(id.lowercased()) }
                } else {
                    // Dossier d'éditeur (« Microsoft Office », « OpenVPN Connect ») : un niveau plus bas.
                    for inner in (try? fm.contentsOfDirectory(at: child, includingPropertiesForKeys: nil)) ?? [] where inner.pathExtension == "app" {
                        if let id = Bundle(url: inner)?.bundleIdentifier { ids.insert(id.lowercased()) }
                    }
                }
            }
        }
        return ids
    }

    public static func read(_ url: URL) -> InstalledApp? {
        let info = (try? Data(contentsOf: url.appending(path: "Contents/Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        let bundleID = info["CFBundleIdentifier"] as? String
        let resolved = url.resolvingSymlinksInPath().path
        // Safari et les apps d'Apple livrées avec macOS sont des liens vers le volume système.
        let isSystem = resolved.hasPrefix("/System/") || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
        return InstalledApp(
            url: url, name: url.deletingPathExtension().lastPathComponent,
            bundleID: bundleID,
            version: info["CFBundleShortVersionString"] as? String,
            lastUsed: lastUsed(url),
            fromAppStore: FileManager.default.fileExists(atPath: url.appending(path: "Contents/_MASReceipt").path),
            isSystem: isSystem,
            deletable: FileManager.default.isDeletableFile(atPath: url.path) && isOwnedByUser(url)
        )
    }

    /// Dernière ouverture selon Spotlight (`kMDItemLastUsedDate`).
    public static func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    static func isOwnedByUser(_ url: URL) -> Bool {
        let owner = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.ownerAccountID] as? NSNumber
        return owner?.uint32Value == getuid()
    }

    // MARK: Données d'une app

    public struct Part: Sendable, Hashable, Identifiable {
        public var url: URL
        public var kind: String
        /// Réglages : gardés si « Garder les réglages » est coché.
        public var isPreference: Bool
        /// Conteneur d'app sandboxée : macOS demande l'autorisation pour y accéder, sa taille n'est pas mesurée.
        public var isContainer: Bool

        public var id: String { url.path }
    }

    /// Emplacements des données d'une app, par identifiant et par nom exact.
    public static func parts(bundleID: String?, name: String, home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [Part] {
        let library = home.appending(path: "Library")
        var found: [Part] = []
        let fm = FileManager.default
        func add(_ relative: String, _ kind: String, preference: Bool = false, container: Bool = false) {
            let url = library.appending(path: relative)
            guard fm.fileExists(atPath: url.path), !found.contains(where: { $0.url == url }) else { return }
            found.append(Part(url: url, kind: kind, isPreference: preference, isContainer: container))
        }
        if let id = bundleID {
            add("Application Support/\(id)", "Données")
            add("Caches/\(id)", "Cache")
            add("HTTPStorages/\(id)", "Cookies et cache web")
            add("HTTPStorages/\(id).binarycookies", "Cookies")
            add("WebKit/\(id)", "Données web")
            add("Saved Application State/\(id).savedState", "État des fenêtres")
            add("Logs/\(id)", "Journaux")
            add("Containers/\(id)", "Conteneur (données de l’app sandboxée)", container: true)
            add("Preferences/\(id).plist", "Réglages", preference: true)
            let byHost = library.appending(path: "Preferences/ByHost")
            for file in (try? fm.contentsOfDirectory(atPath: byHost.path)) ?? [] where file.hasPrefix(id + ".") && file.hasSuffix(".plist") {
                add("Preferences/ByHost/\(file)", "Réglages (cet ordinateur)", preference: true)
            }
            let agents = library.appending(path: "LaunchAgents")
            for file in (try? fm.contentsOfDirectory(atPath: agents.path)) ?? [] where file.hasPrefix(id) && file.hasSuffix(".plist") {
                add("LaunchAgents/\(file)", "Agent de démarrage")
            }
        }
        if !name.isEmpty, !Self.genericNames.contains(name.lowercased()) {
            add("Application Support/\(name)", "Données")
            add("Caches/\(name)", "Cache")
            add("Logs/\(name)", "Journaux")
        }
        return found
    }

    /// Noms trop généraux pour être rapprochés d'un dossier.
    static let genericNames: Set<String> = ["app", "data", "helper", "google", "microsoft", "apple", "adobe", "caches", "logs"]

    // MARK: Plan de désinstallation

    /// Désinstallation : quitter l'app si elle est ouverte, `brew uninstall --cask` si elle vient de Homebrew,
    /// sinon la corbeille (le Finder demande le mot de passe si l'app appartient au système), puis les données choisies.
    public static func uninstallPlan(
        app: InstalledApp, parts: [(Part, Int64)], running: ProcessTarget?, brew: (path: String, cask: String)?
    ) -> ActionPlan {
        var steps: [ActionStep] = []
        if let running { steps.append(.signal(running, force: false)) }
        let appBytes = app.bytes ?? 0
        var skipped: [String] = []
        if let brew {
            steps.append(.command(CommandSpec(brew.path, ["uninstall", "--cask", brew.cask])))
        } else if app.deletable {
            steps.append(.remove(app.url, bytes: appBytes, permanently: false))
        } else {
            // Paquet installé par le système (App Store) : le Finder demande l'autorisation (règle n° 4).
            steps.append(.command(CommandSpec("/usr/bin/osascript", [
                "-e", "tell application \"Finder\" to delete (POSIX file \(AppleScript.quote(app.url.path)) as alias)",
            ])))
            skipped.append("\(app.name) appartient au système : le Finder demandera votre mot de passe.")
        }
        for (part, bytes) in parts {
            steps.append(.remove(part.url, bytes: bytes, permanently: false))
        }
        let total = appBytes + parts.reduce(0) { $0 + $1.1 }
        let summary = [
            running != nil ? "\(app.name) est ouverte : elle sera quittée proprement d’abord." : nil,
            brew != nil ? "Installée via Homebrew : désinstallée par brew, puis ses données vont à la corbeille." : "L’app et ses données vont à la corbeille.",
        ].compactMap { $0 }.joined(separator: " ")
        return ActionPlan(
            title: "Désinstaller \(app.name)", summary: summary, kind: .nettoyage, risk: .caution,
            reversible: brew == nil && app.deletable, steps: steps, estimatedBytes: total, skipped: skipped
        )
    }
}

public enum AppleScript {
    /// Chaîne AppleScript entre guillemets.
    public static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - Restes d'apps

public struct LeftoverScanner: Sendable {
    public var home: URL
    /// Identifiants des apps présentes (en minuscules).
    public var installedIDs: Set<String>
    /// Identifiants des apps ouvertes (en minuscules) : jamais touchées.
    public var runningIDs: Set<String>
    public var now: Date

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), installedIDs: Set<String>, runningIDs: Set<String> = [], now: Date = .now) {
        self.home = home
        self.installedIDs = installedIDs
        self.runningIDs = runningIDs
        self.now = now
    }

    /// Dossiers où les apps laissent des données, cherchés par identifiant.
    static let folders = ["Application Support", "Caches", "HTTPStorages", "WebKit", "Saved Application State", "Logs", "Preferences"]

    /// Dossiers nommés d'après l'app (pas d'identifiant) : nom → identifiant de l'app.
    static let knownFolders: [String: (id: String, name: String)] = [
        "Code": ("com.microsoft.VSCode", "Visual Studio Code"), "Cursor": ("com.todesktop.230313mzl4w4u92", "Cursor"),
        "Arc": ("company.thebrowser.Browser", "Arc"), "Zed": ("dev.zed.Zed", "Zed"), "Postman": ("com.postmanlabs.mac", "Postman"),
        "obsidian": ("md.obsidian", "Obsidian"), "Vivaldi": ("com.vivaldi.Vivaldi", "Vivaldi"),
        "BraveSoftware": ("com.brave.Browser", "Brave"), "Microsoft Edge": ("com.microsoft.edgemac", "Microsoft Edge"),
        "Slack": ("com.tinyspeck.slackmacgap", "Slack"), "discord": ("com.hnc.Discord", "Discord"),
        "Spotify": ("com.spotify.client", "Spotify"), "zoom.us": ("us.zoom.xos", "Zoom"), "Notion": ("notion.id", "Notion"),
        "Figma": ("com.figma.Desktop", "Figma"), "VSCodium": ("com.vscodium", "VSCodium"),
        "Perplexity": ("ai.perplexity.mac", "Perplexity"), "Comet": ("ai.perplexity.comet", "Comet"),
        "qBittorrent": ("org.qbittorrent.qBittorrent", "qBittorrent"), "TorBrowser-Data": ("org.torproject.torbrowser", "Tor Browser"),
        "Stats": ("eu.exelban.Stats", "Stats"), "LibreOffice": ("org.libreoffice.script", "LibreOffice"),
        "Blender": ("org.blenderfoundation.blender", "Blender"), "Docker Desktop": ("com.docker.docker", "Docker"),
        "iTerm2": ("com.googlecode.iterm2", "iTerm"), "Claude": ("com.anthropic.claudefordesktop", "Claude"),
        "Ollama": ("com.electron.ollama", "Ollama"), "Qobuz": ("com.qobuz.QobuzDesktop", "Qobuz"),
        "balenaEtcher": ("io.balena.etcher", "balenaEtcher"), "NotepadNext": ("com.github.dail8859.NotepadNext", "NotepadNext"),
        "Focusrite": ("com.focusrite.control", "Focusrite Control"), "LogiOptionsPlus": ("com.logi.optionsplus", "Logi Options+"),
        "GOG.com": ("com.gog.galaxy", "GOG Galaxy"), "minecraft": ("com.mojang.minecraftlauncher", "Minecraft"),
    ]

    /// Noms lisibles d'identifiants courants.
    static let knownNames: [String: String] = [
        "com.todesktop.230313mzl4w4u92": "Cursor", "us.zoom.xos": "Zoom", "notion.id": "Notion", "com.microsoft.vscode": "Visual Studio Code",
        "com.tinyspeck.slackmacgap": "Slack", "com.hnc.discord": "Discord", "company.thebrowser.browser": "Arc",
        "com.spotify.client": "Spotify", "md.obsidian": "Obsidian", "com.figma.desktop": "Figma", "com.adobe.acc": "Adobe Creative Cloud",
        "com.anysphere.sand": "Cursor", "com.operasoftware.opera": "Opera", "com.duckduckgo.macos.browser": "DuckDuckGo",
        "com.electron.dockerdesktop": "Docker Desktop", "com.mojang.minecraftlauncher": "Minecraft", "ch.sudo.cyberduck": "Cyberduck",
        "com.makemkv.makemkv": "MakeMKV", "com.linphone.linphone": "Linphone", "com.paragon-software.ntfs.fsapp": "NTFS for Mac",
    ]

    /// Identifiants qui ne sont pas des apps (bibliothèques, outils) : ignorés.
    static let ignoredPrefixes = ["com.apple.", "group.", "org.sparkle-project", "io.sentry", "com.crashlytics", "com.firebase",
                                  "com.google.gmp", "com.launchdarkly", "local.latelier", "com.breakpad", "com.docker.install",
                                  "org.python", "org.nodejs", "com.plausiblelabs", "com.segment",
                                  // Outils et bibliothèques, pas des apps :
                                  "org.swift.", "org.cups.", "org.webkit.", "com.qtproject", "org.cef.", "org.chromium.", "com.electron.",
                                  "com.jetbrains.toolbox"]

    public static func looksLikeBundleID(_ name: String) -> Bool {
        if knownNames[name.lowercased()] != nil { return true }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }),
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else { return false }
        let tlds: Set<String> = ["com", "org", "net", "io", "us", "de", "fr", "co", "app", "dev", "me", "ai", "uk", "jp", "info",
                                 "cc", "tv", "eu", "ch", "md", "company", "so", "sh", "xyz", "it", "nl", "be", "ca", "se"]
        return tlds.contains(String(parts[0]).lowercased()) && (parts.count >= 3 || parts[1].count >= 2)
    }

    /// Éditeur d'un identifiant (`com.google.Keystone` → `com.google`).
    static func organization(_ id: String) -> String {
        id.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
    }

    public func isInstalled(_ id: String) -> Bool {
        let lower = id.lowercased()
        if installedIDs.contains(lower) || runningIDs.contains(lower) { return true }
        // Même éditeur qu'une app présente (aides, mises à jour, données partagées) : on ne touche pas.
        let org = Self.organization(lower)
        return installedIDs.contains { Self.organization($0) == org } || runningIDs.contains { Self.organization($0) == org }
    }

    public struct Leftover: Sendable, Identifiable {
        public var id: String
        public var name: String
        public var urls: [URL]
        public var folders: [String]
        public var modified: Date?
    }

    /// Restes regroupés par identifiant d'app.
    public func scan() -> [Leftover] {
        let library = home.appending(path: "Library")
        let fm = FileManager.default
        var groups: [String: Leftover] = [:]
        for folder in Self.folders {
            let base = library.appending(path: folder)
            for child in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                var name = child.lastPathComponent
                var displayName: String?
                if folder == "Preferences" {
                    guard name.hasSuffix(".plist") else { continue }
                    name = String(name.dropLast(6))
                }
                if folder == "Saved Application State" {
                    guard name.hasSuffix(".savedState") else { continue }
                    name = String(name.dropLast(11))
                }
                if folder == "HTTPStorages", name.hasSuffix(".binarycookies") { name = String(name.dropLast(14)) }
                var id = name
                if let known = Self.knownFolders[name], folder != "Preferences" {
                    id = known.id
                    displayName = known.name
                } else if !Self.looksLikeBundleID(name) {
                    continue
                }
                let lower = id.lowercased()
                guard !Self.ignoredPrefixes.contains(where: { lower.hasPrefix($0) }), !isInstalled(id) else { continue }
                let modified = (try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                var group = groups[lower] ?? Leftover(id: lower, name: displayName ?? Self.readableName(id), urls: [], folders: [], modified: nil)
                group.urls.append(child)
                if !group.folders.contains(folder) { group.folders.append(folder) }
                if let modified { group.modified = max(group.modified ?? modified, modified) }
                groups[lower] = group
            }
        }
        return Array(groups.values)
    }

    /// « com.todesktop.230313mzl4w4u92 » → Cursor ; « com.example.SuperApp » → SuperApp.
    static func readableName(_ id: String) -> String {
        if let known = knownNames[id.lowercased()] { return known }
        let parts = id.split(separator: ".").map(String.init)
        let candidates = parts.dropFirst().reversed().filter { part in
            !["mac", "macos", "osx", "desktop", "app", "client", "helper", "plist"].contains(part.lowercased())
                && part.contains(where: \.isLetter) && !(part.count > 10 && part.filter(\.isNumber).count > 3)
        }
        guard let pick = candidates.first else { return id }
        return pick.prefix(1).uppercased() + pick.dropFirst()
    }

    /// Lignes de nettoyage, une par app (sizes : tailles mesurées par URL), de la plus lourde à la plus légère.
    public func items(_ leftovers: [Leftover], sizes: [URL: Int64]) -> [CleanupItem] {
        leftovers.compactMap { leftover -> CleanupItem? in
            let entries = leftover.urls.map { CleanupItem.Entry(url: $0, bytes: sizes[$0] ?? 0) }
            guard entries.reduce(0, { $0 + $1.bytes }) > 0 else { return nil }
            let old = leftover.modified.map { now.timeIntervalSince($0) > 90 * 86_400 } ?? true
            return CleanupItem(
                id: "leftover:" + leftover.id, name: leftover.name,
                detail: "\(leftover.id) · \(leftover.folders.joined(separator: ", "))",
                meta: leftover.modified.map { "Modifié \(RelativeDate.french($0, now: now))" },
                metaHighlighted: old, risk: old ? .safe : .caution, selectedByDefault: old, entries: entries
            )
        }
        .sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
    }

    /// Installations interrompues connues.
    public func interruptedInstalls() -> [URL] {
        let candidates = ["Library/Application Support/com.docker.install/in_progress"]
        return candidates.map { home.appending(path: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

// MARK: - Liens morts

public enum DeadLinks {
    public struct Link: Sendable, Hashable {
        public var url: URL
        public var destination: String
    }

    /// Liens de `/usr/local/bin` vers une app qui n'existe plus.
    public static func find(in directory: URL = URL(fileURLWithPath: "/usr/local/bin")) -> [Link] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).compactMap { name -> Link? in
            let url = directory.appending(path: name)
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: url.path) else { return nil }
            let absolute = destination.hasPrefix("/") ? destination : directory.appending(path: destination).standardizedFileURL.path
            guard absolute.contains(".app/"), !fm.fileExists(atPath: absolute) else { return nil }
            return Link(url: url, destination: absolute)
        }
        .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    /// Nom de l'app visée (« Docker.app »).
    public static func appName(_ link: Link) -> String {
        link.destination.split(separator: "/").first { $0.hasSuffix(".app") }.map(String.init) ?? link.destination
    }

    /// Suppression avec le mot de passe administrateur (demande explicite de macOS, règle n° 4).
    public static func removalCommand(_ links: [Link]) -> CommandSpec? {
        let safe = links.filter { link in
            link.url.deletingLastPathComponent().path == "/usr/local/bin"
                && link.url.lastPathComponent.allSatisfy { $0.isLetter || $0.isNumber || "._+-".contains($0) }
        }
        guard !safe.isEmpty else { return nil }
        let paths = safe.map { "'\($0.url.path)'" }.joined(separator: " ")
        return CommandSpec("/usr/bin/osascript", ["-e", "do shell script \(AppleScript.quote("/bin/rm -f \(paths)")) with administrator privileges"])
    }
}
