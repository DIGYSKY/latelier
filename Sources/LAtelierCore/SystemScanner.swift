import Foundation

/// Stockage › Système : caches utilisateur, logs, corbeille.
public struct SystemScanner: Sendable {
    public var home: URL
    /// Identifiants des apps ouvertes : leurs caches ne sont pas touchés (règle n° 3).
    public var runningBundleIDs: Set<String>
    /// Nom lisible d'une app à partir de son identifiant (fourni par l'app, via AppKit).
    public var appName: @Sendable (String) -> String?
    /// En dessous, les caches sont regroupés dans « Autres caches ».
    public var smallThreshold: Int64 = 50_000_000
    public var ownBundleID = AppPaths.bundleIdentifier

    public init(
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        runningBundleIDs: Set<String> = [],
        appName: @escaping @Sendable (String) -> String? = { _ in nil }
    ) {
        self.home = home
        self.runningBundleIDs = runningBundleIDs
        self.appName = appName
    }

    public func scan() async -> [CleanupGroup] {
        async let caches = cachesGroup()
        async let logs = logsGroup()
        async let trash = trashGroup()
        return await [caches, logs, trash].compactMap { $0 }
    }

    func cachesGroup() async -> CleanupGroup? {
        let root = home.appendingPathComponent("Library/Caches")
        let children = Self.children(of: root).filter { $0.lastPathComponent != ownBundleID }
        let sizes = await DiskUsage.measure(children)
        let running = Set(runningBundleIDs.map { $0.lowercased() })

        var items: [CleanupItem] = []
        var small: [CleanupItem.Entry] = []
        var system: [CleanupItem.Entry] = []
        for url in children {
            let size = sizes[url]?.bytes ?? 0
            guard size > 0 else { continue }
            let name = url.lastPathComponent
            let entry = CleanupItem.Entry(url: url, bytes: size)
            if name.hasPrefix("com.apple.") {
                system.append(entry)
            } else if running.contains(name.lowercased()) {
                items.append(CleanupItem(
                    id: url.path, name: appName(name) ?? name,
                    detail: "Ignoré : l’app est ouverte. Quittez-la pour nettoyer.",
                    meta: "—", tag: "App ouverte", risk: .protected,
                    lockReason: "l’app est ouverte", selectedByDefault: false, entries: [entry]
                ))
            } else if size < smallThreshold {
                small.append(entry)
            } else {
                items.append(CleanupItem(
                    id: url.path, name: appName(name) ?? name, detail: url.abbreviatingHome(home.path),
                    detailIsPath: true, entries: [entry]
                ))
            }
        }
        items.sort { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
        if !small.isEmpty {
            items.append(CleanupItem(
                id: root.path + "#small", name: "Autres caches",
                detail: "\(small.count) dossiers de moins de \(ByteCountFormatter.string(fromByteCount: smallThreshold, countStyle: .file))",
                meta: "\(small.count) dossiers", entries: small
            ))
        }
        if !system.isEmpty {
            items.append(CleanupItem(
                id: root.path + "#apple", name: "Caches de macOS",
                detail: "\(system.count) dossiers com.apple.* : gérés par le système, on n’y touche pas.",
                meta: "\(system.count) dossiers", risk: .protected,
                lockReason: "géré par macOS", selectedByDefault: false, entries: system
            ))
        }
        guard !items.isEmpty else { return nil }
        return CleanupGroup(
            id: "caches", title: "Caches utilisateur",
            detail: "~/Library/Caches · recréés par les apps au besoin", items: items
        )
    }

    func logsGroup() async -> CleanupGroup? {
        let root = home.appendingPathComponent("Library/Logs")
        let diagnostics = root.appendingPathComponent("DiagnosticReports")
        let appLogs = Self.children(of: root).filter { $0.lastPathComponent != "DiagnosticReports" }
        let reports = Self.children(of: diagnostics)
        let sizes = await DiskUsage.measure(appLogs + reports)

        func item(_ id: String, _ name: String, _ folder: URL, _ urls: [URL], unit: String) -> CleanupItem? {
            let entries = urls.map { CleanupItem.Entry(url: $0, bytes: sizes[$0]?.bytes ?? 0) }.filter { $0.bytes > 0 }
            guard !entries.isEmpty else { return nil }
            let files = urls.reduce(0) { $0 + (sizes[$1]?.files ?? 0) }
            return CleanupItem(
                id: id, name: name, detail: folder.abbreviatingHome(home.path), detailIsPath: true,
                meta: "\(files) \(unit)\(files > 1 ? "s" : "")", entries: entries
            )
        }
        let items = [
            item("logs", "Logs d’apps", root, appLogs, unit: "fichier"),
            item("diagnostics", "Rapports de diagnostic", diagnostics, reports, unit: "rapport"),
        ].compactMap { $0 }
        guard !items.isEmpty else { return nil }
        return CleanupGroup(id: "logs", title: "Logs", detail: "Journaux d’apps et rapports de plantage", items: items)
    }

    func trashGroup() async -> CleanupGroup? {
        let trash = home.appendingPathComponent(".Trash")
        guard FileManager.default.fileExists(atPath: trash.path) else { return nil }
        let item: CleanupItem
        if let contents = try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) {
            let visible = contents.filter { $0.lastPathComponent != ".DS_Store" }
            guard !visible.isEmpty else { return nil }
            let sizes = await DiskUsage.measure(visible)
            let total = sizes.values.reduce(Int64(0)) { $0 + $1.bytes }
            item = CleanupItem(
                id: trash.path, name: "Vider la corbeille",
                detail: "~/.Trash · \(visible.count) élément(s)", meta: "Définitif", metaHighlighted: true,
                risk: .caution, selectedByDefault: false, entries: [], action: .emptyTrash, displayBytes: total
            )
        } else {
            // macOS protège ~/.Trash : sans « Accès complet au disque », on ne peut pas la mesurer.
            item = CleanupItem(
                id: trash.path, name: "Vider la corbeille",
                detail: "Taille inconnue : autorisez L’Atelier dans Réglages Système › Confidentialité › Accès complet au disque.",
                meta: "Définitif", metaHighlighted: true, risk: .caution, selectedByDefault: false,
                entries: [], action: .emptyTrash, displayBytes: 0
            )
        }
        return CleanupGroup(id: "trash", title: "Corbeille", detail: "Vider la corbeille est définitif", tone: .neutral, items: [item])
    }

    static func children(of url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]
        )) ?? []
    }
}
