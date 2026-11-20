import Foundation

// MARK: - Dossiers protégés par macOS

/// Dossiers dont la lecture déclenche une demande d'autorisation de macOS (TCC) :
/// ils ne sont mesurés qu'après un choix explicite de l'utilisateur.
public enum PrivacyZones {
    /// Bureau, Documents, Téléchargements : autorisation « Fichiers et dossiers ».
    public static func personal(home: String = NSHomeDirectory()) -> [String] {
        ["Desktop", "Documents", "Downloads"].map { home + "/" + $0 }
    }

    /// Données d'autres apps, iCloud, Photos, Mail… : jamais parcourus.
    public static func alwaysSkipped(home: String = NSHomeDirectory()) -> Set<String> {
        Set([
            "Library/Containers", "Library/Group Containers", "Library/Mobile Documents", "Library/Mail", "Library/Messages",
            "Library/Safari", "Library/Calendars", "Library/Reminders", "Library/Application Support/AddressBook",
            "Library/Application Support/CallHistoryDB", "Library/Application Support/com.apple.TCC", "Library/Cookies",
            "Library/HomeKit", "Library/IdentityServices", "Library/Suggestions", "Library/Biome", "Library/Accounts",
            "Library/CloudStorage", "Library/Daemon Containers", "Library/Metadata/CoreSpotlight", "Library/Trial",
            "Library/Autosave Information", "Library/Sharing", "Library/Photos", "Library/Assistant", "Library/PersonalizationPortrait",
            "Library/DuetExpertCenter", "Library/StatusKit", "Library/Weather", "Library/News", "Library/Stocks",
            ".Trash",
        ].map { home + "/" + $0 })
    }

    public static func skipped(allowPersonal: Bool, home: String = NSHomeDirectory()) -> Set<String> {
        allowPersonal ? alwaysSkipped(home: home) : alwaysSkipped(home: home).union(personal(home: home))
    }

    public static func isPersonal(_ url: URL, home: String = NSHomeDirectory()) -> Bool {
        personal(home: home).contains { url.path == $0 || url.path.hasPrefix($0 + "/") }
    }
}

// MARK: - Vue d'ensemble

public struct DiskCategory: Sendable, Identifiable, Hashable {
    public enum ID: String, Sendable, CaseIterable {
        case macos, sysdata, apps, dev, docs, images, videos, music, downloads, users, trash, other
    }

    public var id: ID
    public var bytes: Int64?
    /// Raison pour laquelle la taille est inconnue (« Autorisation requise »).
    public var note: String?

    public init(id: ID, bytes: Int64?, note: String? = nil) {
        self.id = id
        self.bytes = bytes
        self.note = note
    }
}

/// Une partie de « Autres » : ce qui n'entre dans aucune catégorie.
public struct DiskOtherPart: Sendable, Identifiable, Hashable {
    public var name: String
    public var url: URL?
    /// `nil` : non mesuré (raison dans `note`).
    public var bytes: Int64?
    public var note: String

    public var id: String { url?.path ?? name }
}

public struct DiskOverview: Sendable {
    /// Détail de « Autres », du plus lourd au plus léger.
    public var others: [DiskOtherPart] = []
    public var volumeName: String
    public var total: Int64
    public var available: Int64
    /// Espace « purgeable » que macOS libère seul au besoin (inclus dans `available`).
    public var purgeable: Int64
    public var categories: [DiskCategory]
    public var localSnapshots: Int
    public var duration: TimeInterval

    public var used: Int64 { total - available }

    public func bytes(_ id: DiskCategory.ID) -> Int64? { categories.first { $0.id == id }?.bytes }
}

public struct DiskOverviewScanner: Sendable {
    public var home: URL
    public var runner: CommandRunner
    /// Bureau, Documents, Téléchargements : seulement si l'utilisateur l'a demandé.
    public var allowPersonal: Bool
    /// Dossiers de projets (comptés dans Développeur).
    public var projectRoots: [URL]

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), runner: CommandRunner, allowPersonal: Bool, projectRoots: [URL]) {
        self.home = home
        self.runner = runner
        self.allowPersonal = allowPersonal
        // Un dossier de projets dans Documents n'est lu que si l'accès a été accordé.
        self.projectRoots = allowPersonal ? projectRoots : projectRoots.filter { !PrivacyZones.isPersonal($0, home: home.path) }
    }

    func p(_ relative: String) -> URL { home.appending(path: relative) }

    static let developerFolders = ["Library/Developer", ".npm", ".cargo", ".rustup", ".nvm", ".gradle", ".m2", "go", ".cache", ".pyenv",
                                   ".bun", ".deno", ".docker", ".volta", ".sdkman", ".local", ".android", "Library/Android", "Library/pnpm",
                                   ".yarn", ".pub-cache", ".flutter", ".swiftpm", ".cocoapods", ".composer", ".minikube", ".kube", ".dart-tool"]

    /// Dossiers du dossier personnel déjà rangés dans une catégorie.
    func attributedHomeNames() -> Set<String> {
        var names: Set<String> = ["Library", "Applications", "Pictures", "Movies", "Music", "Documents", "Desktop", "Downloads", ".Trash"]
        for folder in Self.developerFolders where !folder.contains("/") { names.insert(folder) }
        for root in projectRoots where root.deletingLastPathComponent().standardizedFileURL.path == home.standardizedFileURL.path {
            names.insert(root.lastPathComponent)
        }
        return names
    }

    /// Ce qui n'entre dans aucune catégorie : dossiers du dossier personnel, dossiers système lisibles, et ce qui n'est pas mesuré.
    func otherParts(skip: Set<String>, snapshots: Int) async -> [DiskOtherPart] {
        let fm = FileManager.default
        let attributed = attributedHomeNames()
        let homeChildren = ((try? fm.contentsOfDirectory(atPath: home.path)) ?? [])
            .filter { !attributed.contains($0) && $0 != ".DS_Store" && $0 != ".localized" }
            .map { home.appending(path: $0) }
            .filter { !skip.contains($0.path) }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).deletingLastPathComponent()
        let system: [(String, URL, String)] = [
            ("Bibliothèque du Mac (/Library)", URL(fileURLWithPath: "/Library"), "Données partagées des apps, polices, extensions, réglages pour tous les comptes"),
            ("/usr/local", URL(fileURLWithPath: "/usr/local"), "Outils installés hors Homebrew (ou ancien Homebrew Intel)"),
            ("Dossier partagé (/Users/Shared)", URL(fileURLWithPath: "/Users/Shared"), "Fichiers partagés entre les comptes"),
            ("Fichiers temporaires", tmp, "Caches et fichiers temporaires de vos apps (/var/folders), vidés par macOS au redémarrage"),
        ].filter { fm.fileExists(atPath: $0.1.path) }
        let skipping = skip.union(["/Library/Developer"])
        let sizes = await DiskUsage.measure(homeChildren + system.map(\.1), skipping: skipping)
        var parts: [DiskOtherPart] = []
        var small: Int64 = 0
        var smallCount = 0
        for url in homeChildren {
            let bytes = sizes[url]?.bytes ?? 0
            if bytes >= 20_000_000 {
                let (_, description, _) = FolderExplorer.describe(url, home: home.path, projectRoots: projectRoots)
                parts.append(DiskOtherPart(name: "~/" + url.lastPathComponent, url: url, bytes: bytes, note: description))
            } else {
                small += bytes
                smallCount += 1
            }
        }
        if small > 0 {
            parts.append(DiskOtherPart(name: "\(smallCount) petits éléments du dossier personnel", url: home, bytes: small,
                                       note: "Fichiers de configuration (.zshrc, .gitconfig…) et petits dossiers d’outils"))
        }
        for (name, url, note) in system {
            let bytes = sizes[url]?.bytes ?? 0
            if bytes > 0 { parts.append(DiskOtherPart(name: name, url: url, bytes: bytes, note: note)) }
        }
        parts.sort { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        // Ce qui n'est pas mesuré, et pourquoi.
        if !allowPersonal {
            parts.append(DiskOtherPart(name: "Documents, Bureau, Téléchargements", url: nil, bytes: nil,
                                       note: "Non mesurés : macOS demande votre autorisation (bouton « Inclure ces dossiers… »)"))
        }
        parts.append(DiskOtherPart(name: "Conteneurs d’apps (~/Library/Containers, Group Containers)", url: p("Library/Containers"), bytes: nil,
                                   note: "Non mesurés : données protégées des autres apps. Le disque virtuel de Docker (Docker.raw) y est rangé"))
        if snapshots > 0 {
            parts.append(DiskOtherPart(name: "\(snapshots) instantané\(snapshots > 1 ? "s" : "") Time Machine locaux", url: nil, bytes: nil,
                                       note: "Gérés par macOS : supprimés automatiquement quand la place manque"))
        }
        return parts
    }

    /// Emplacements de chaque catégorie mesurée.
    func locations() -> [DiskCategory.ID: [URL]] {
        let developer = Self.developerFolders.map(p) + projectRoots
            + [URL(fileURLWithPath: "/opt/homebrew"), URL(fileURLWithPath: "/Library/Developer")]
        var result: [DiskCategory.ID: [URL]] = [
            // ~/Library (sans Developer, compté dans Développeur, ni les données protégées) et le swap.
            .sysdata: [p("Library"), URL(fileURLWithPath: "/private/var/vm")],
            .apps: AppInventory.roots(home: home.path),
            .dev: developer,
            .images: [p("Pictures")],
            .videos: [p("Movies")],
            .music: [p("Music")],
        ]
        if allowPersonal {
            result[.docs] = [p("Documents"), p("Desktop")]
            result[.downloads] = [p("Downloads")]
        }
        // Un dossier de projet dans Documents n'est compté qu'une fois (dans Développeur).
        return result.mapValues { urls in urls.filter { FileManager.default.fileExists(atPath: $0.path) } }
    }

    public func scan() async -> DiskOverview {
        let start = Date()
        let volume = URL(fileURLWithPath: "/")
        let values = try? volume.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                                          .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey])
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let free = Int64(values?.volumeAvailableCapacity ?? 0)
        let important = values?.volumeAvailableCapacityForImportantUsage ?? Int64(free)
        async let system = systemVolumeBytes()
        async let snapshots = localSnapshotCount()

        let skip = PrivacyZones.skipped(allowPersonal: allowPersonal, home: home.path)
            // Les projets sont comptés à part : pas deux fois dans Documents.
            .union(projectRoots.map(\.path))
        let locations = locations()
        var measured: [DiskCategory.ID: Int64] = [:]
        for (id, urls) in locations {
            // Les projets ne sont pas exclus de Développeur.
            var skipping = id == .dev ? skip.subtracting(projectRoots.map(\.path)) : skip
            if id == .sysdata { skipping.insert(p("Library/Developer").path) }
            let sizes = await DiskUsage.measure(urls, skipping: skipping)
            measured[id] = sizes.values.reduce(0) { $0 + $1.bytes }
        }
        let macos = await system
        var categories: [DiskCategory] = [DiskCategory(id: .macos, bytes: macos)]
        for id in [DiskCategory.ID.sysdata, .apps, .dev, .docs, .images, .videos, .music, .downloads] {
            if let bytes = measured[id] {
                categories.append(DiskCategory(id: id, bytes: bytes))
            } else {
                categories.append(DiskCategory(id: id, bytes: nil, note: "Autorisation requise"))
            }
        }
        let otherAccounts = otherUsers()
        categories.append(DiskCategory(id: .users, bytes: nil, note: otherAccounts == 0 ? "Aucun autre compte" : "\(otherAccounts) compte\(otherAccounts > 1 ? "s" : "") · lecture seule"))
        let trash = trashBytes()
        categories.append(DiskCategory(id: .trash, bytes: trash, note: trash == nil ? "Accès complet au disque requis" : nil))
        let used = total - Int64(important)
        let attributed = categories.compactMap(\.bytes).reduce(0, +)
        let otherBytes = max(0, used - attributed)
        categories.append(DiskCategory(id: .other, bytes: otherBytes,
                                       note: allowPersonal ? nil : "Comprend Documents, Bureau et Téléchargements, non mesurés"))
        let snapshotCount = await snapshots
        var others = await otherParts(skip: skip, snapshots: snapshotCount)
        let identified = others.compactMap { $0.bytes }.reduce(0, +)
        if otherBytes > identified {
            others.append(DiskOtherPart(name: "Reste non identifié", url: nil, bytes: otherBytes - identified,
                                        note: "Ce qui n’est pas lisible sans droits (conteneurs, instantanés, fichiers système, autres comptes)"))
        }
        return DiskOverview(
            others: others, volumeName: values?.volumeLocalizedName ?? "Macintosh HD", total: total, available: Int64(important),
            purgeable: max(0, Int64(important) - free), categories: categories,
            localSnapshots: snapshotCount, duration: Date().timeIntervalSince(start)
        )
    }

    /// Taille du volume système scellé (`diskutil info /`).
    func systemVolumeBytes() async -> Int64? {
        guard let result = try? await runner.run(CommandSpec("/usr/sbin/diskutil", ["info", "-plist", "/"]), timeout: .seconds(10)),
              result.succeeded,
              let plist = try? PropertyListSerialization.propertyList(from: Data(result.stdout.joined(separator: "\n").utf8), format: nil) as? [String: Any]
        else { return nil }
        return (plist["CapacityInUse"] as? NSNumber)?.int64Value
    }

    func localSnapshotCount() async -> Int {
        guard let result = try? await runner.run(CommandSpec("/usr/bin/tmutil", ["listlocalsnapshots", "/"]), timeout: .seconds(10)),
              result.succeeded else { return 0 }
        return result.stdout.filter { $0.contains("com.apple.TimeMachine") }.count
    }

    func otherUsers() -> Int {
        let me = home.lastPathComponent
        return ((try? FileManager.default.contentsOfDirectory(atPath: "/Users")) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != me && $0 != "Shared" && $0 != "Guest" }.count
    }

    func trashBytes() -> Int64? {
        let trash = p(".Trash")
        guard let items = try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) else { return nil }
        return items.reduce(0) { $0 + DiskUsage.measure($1).bytes }
    }
}

// MARK: - Explorateur

public struct FolderNode: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable {
        /// Récupérable sans risque (caches, artefacts).
        case safe
        /// À examiner (données d'apps, téléchargements).
        case review
        /// Vos fichiers : jamais proposés au nettoyage.
        case personal
        /// Protégé (toolchains, système).
        case protected
    }

    public var url: URL
    public var name: String
    public var bytes: Int64?
    public var isDirectory: Bool
    public var kind: Kind
    public var description: String
    /// Écran de L’Atelier qui sait nettoyer ce dossier.
    public var screen: String?
    /// Non mesuré : autorisation de macOS nécessaire.
    public var needsPermission: Bool

    public var id: String { url.path }
}

public enum FolderExplorer {
    struct Known {
        var kind: FolderNode.Kind
        var description: String
        var screen: String?
    }

    /// Descriptions en clair des dossiers connus, par chemin relatif au dossier personnel.
    static let known: [String: Known] = [
        "Library": Known(kind: .review, description: "Réglages, caches et données des apps. Le plus gros gisement de place récupérable."),
        "Library/Caches": Known(kind: .safe, description: "Caches des apps, recréés automatiquement.", screen: "systeme"),
        "Library/Logs": Known(kind: .safe, description: "Journaux d’apps et rapports de plantage.", screen: "systeme"),
        "Library/Developer": Known(kind: .safe, description: "DerivedData et simulateurs Xcode : recréés au besoin.", screen: "caches"),
        "Library/Application Support": Known(kind: .review, description: "Données des apps. Contient parfois des restes d’apps désinstallées.", screen: "appsNettoyage"),
        "Library/Containers": Known(kind: .review, description: "Données des apps sandboxées. macOS demande l’autorisation pour y lire : non mesuré.", screen: "desinstalleur"),
        "Library/Group Containers": Known(kind: .review, description: "Données partagées entre apps d’un même éditeur. Non mesuré (autorisation de macOS)."),
        "Library/Mobile Documents": Known(kind: .personal, description: "iCloud Drive. Non mesuré."),
        "Library/HTTPStorages": Known(kind: .safe, description: "Cookies et caches web des apps."),
        "Library/pnpm": Known(kind: .safe, description: "Magasin de paquets pnpm.", screen: "caches"),
        "Library/Android": Known(kind: .review, description: "SDK Android et émulateurs."),
        "Movies": Known(kind: .personal, description: "Vos vidéos. Jamais proposé au nettoyage : triez-les au Sonar.", screen: "sonar"),
        "Music": Known(kind: .personal, description: "Votre musique et la bibliothèque Musique.", screen: "sonar"),
        "Pictures": Known(kind: .personal, description: "Vos images. La Photothèque n’est pas parcourue.", screen: "sonar"),
        "Documents": Known(kind: .personal, description: "Vos documents. Jamais proposé au nettoyage.", screen: "sonar"),
        "Desktop": Known(kind: .personal, description: "Le Bureau. Jamais proposé au nettoyage.", screen: "sonar"),
        "Downloads": Known(kind: .review, description: "Téléchargements : installeurs et archives oubliés à trier au Sonar.", screen: "sonar"),
        "Applications": Known(kind: .review, description: "Apps installées pour vous seul.", screen: "desinstalleur"),
        ".Trash": Known(kind: .safe, description: "La corbeille.", screen: "systeme"),
        ".npm": Known(kind: .safe, description: "Cache npm.", screen: "caches"),
        ".cache": Known(kind: .review, description: "Caches d’outils divers, au cas par cas.", screen: "caches"),
        ".m2": Known(kind: .review, description: "Dépôt Maven local.", screen: "caches"),
        ".gradle": Known(kind: .review, description: "Caches Gradle.", screen: "caches"),
        ".rustup": Known(kind: .protected, description: "Toolchains Rust : protégées."),
        ".cargo": Known(kind: .review, description: "Binaires cargo (protégés) et registre des crates (recréable).", screen: "caches"),
        ".nvm": Known(kind: .protected, description: "Versions de Node.js : protégées.", screen: "runtimes"),
        ".pyenv": Known(kind: .protected, description: "Versions de Python : protégées.", screen: "runtimes"),
        ".docker": Known(kind: .review, description: "Configuration et extensions de la CLI Docker.", screen: "docker"),
        ".ollama": Known(kind: .review, description: "Modèles Ollama téléchargés : longs à re-télécharger."),
        ".vscode": Known(kind: .review, description: "Extensions de Visual Studio Code."),
        ".local": Known(kind: .review, description: "Outils installés pour vous seul (pipx, uv, mise…)."),
        ".espressif": Known(kind: .review, description: "Toolchains ESP-IDF (Espressif) : lourdes à réinstaller, à garder si vous programmez des ESP32."),
        ".codex": Known(kind: .review, description: "Données et sessions de Codex (OpenAI)."),
        ".claude": Known(kind: .review, description: "Réglages, sessions et mémoire de Claude Code."),
        ".lmstudio": Known(kind: .review, description: "Modèles LM Studio téléchargés : longs à re-télécharger."),
        ".yarn": Known(kind: .safe, description: "Cache et versions de Yarn.", screen: "caches"),
        ".bun": Known(kind: .review, description: "Bun et son cache de paquets.", screen: "caches"),
        ".android": Known(kind: .review, description: "Réglages et émulateurs Android."),
        "kDrive": Known(kind: .personal, description: "Dossier synchronisé kDrive (Infomaniak) : vos fichiers."),
        "go": Known(kind: .review, description: "Modules Go (recréables) et binaires go install.", screen: "caches"),
    ]

    public static func describe(_ url: URL, home: String = NSHomeDirectory(), projectRoots: [URL] = []) -> (FolderNode.Kind, String, String?) {
        let relative = url.path == home ? "" : url.path.hasPrefix(home + "/") ? String(url.path.dropFirst(home.count + 1)) : url.path
        if let known = known[relative] { return (known.kind, known.description, known.screen) }
        if projectRoots.contains(url) {
            return (.review, "Vos projets de code. Seuls les artefacts de build sont proposés.", "dev")
        }
        if projectRoots.contains(where: { url.path.hasPrefix($0.path + "/") }) {
            return (.personal, "Projet de code : seuls node_modules, target, .venv… sont proposés.", "dev")
        }
        let name = url.lastPathComponent
        if ["node_modules", "target", ".venv", "venv", "__pycache__", ".next", ".nuxt", ".turbo", "DerivedData", ".gradle"].contains(name) {
            return (.safe, "Artefact de build, recréable.", "dev")
        }
        if relative.hasPrefix("Library/Caches/") { return (.safe, "Cache d’app.", "systeme") }
        if relative.hasPrefix("Library/Application Support/") { return (.review, "Données d’une app.", "appsNettoyage") }
        if relative.hasPrefix("Library/") { return (.review, "Données de macOS ou des apps.", nil) }
        if url.path.hasPrefix("/Applications") { return (.review, "App installée.", "desinstalleur") }
        if name.hasPrefix(".") { return (.review, "Dossier caché d’un outil.", nil) }
        return (.personal, "Vos fichiers. Jamais proposé au nettoyage.", nil)
    }

    /// Contenu d'un dossier avec la taille de chaque élément, du plus lourd au plus léger.
    public static func children(of folder: URL, allowPersonal: Bool, projectRoots: [URL] = [], home: String = NSHomeDirectory()) async -> [FolderNode] {
        let fm = FileManager.default
        // Chemins reconstruits depuis `folder` : contentsOfDirectory peut rendre /private/var pour /var.
        let urls = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).map { folder.appending(path: $0) }
        let skip = PrivacyZones.skipped(allowPersonal: allowPersonal, home: home)
        let measurable = urls.filter { !skip.contains($0.path) && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
        let sizes = await DiskUsage.measure(measurable, skipping: skip)
        return urls.compactMap { url -> FolderNode? in
            guard url.lastPathComponent != ".DS_Store", url.lastPathComponent != ".localized" else { return nil }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let (kind, description, screen) = describe(url, home: home, projectRoots: projectRoots)
            let needsPermission = skip.contains(url.path)
            return FolderNode(url: url, name: url.lastPathComponent, bytes: needsPermission ? nil : sizes[url]?.bytes,
                              isDirectory: isDirectory && url.pathExtension != "app", kind: kind, description: description,
                              screen: screen, needsPermission: needsPermission)
        }
        .filter { $0.needsPermission || ($0.bytes ?? 0) > 0 }
        .sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }
    }
}

/// Treemap : rectangles proportionnels, découpe binaire équilibrée (comme la maquette).
public enum Treemap {
    public struct Rect: Sendable, Equatable {
        public var index: Int
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
    }

    public static func layout(_ values: [Double], width: Double, height: Double) -> [Rect] {
        var rects: [Rect] = []
        let items = values.enumerated().filter { $0.element > 0 }.map { (index: $0.offset, value: $0.element) }
        split(items, x: 0, y: 0, w: width, h: height, into: &rects)
        return rects.sorted { $0.index < $1.index }
    }

    private static func split(_ items: [(index: Int, value: Double)], x: Double, y: Double, w: Double, h: Double, into rects: inout [Rect]) {
        guard !items.isEmpty else { return }
        if items.count == 1 {
            rects.append(Rect(index: items[0].index, x: x, y: y, width: w, height: h))
            return
        }
        let total = items.reduce(0) { $0 + $1.value }
        var acc = 0.0
        var cut = 0
        while cut < items.count - 1 && acc + items[cut].value <= total / 2 {
            acc += items[cut].value
            cut += 1
        }
        if cut == 0 {
            acc = items[0].value
            cut = 1
        }
        let f = acc / total
        let first = Array(items[..<cut]), rest = Array(items[cut...])
        if w >= h {
            split(first, x: x, y: y, w: w * f, h: h, into: &rects)
            split(rest, x: x + w * f, y: y, w: w * (1 - f), h: h, into: &rects)
        } else {
            split(first, x: x, y: y, w: w, h: h * f, into: &rects)
            split(rest, x: x, y: y + h * f, w: w, h: h * (1 - f), into: &rects)
        }
    }
}
