import Foundation

/// Stockage › Développement : artefacts de build recréables, regroupés par projet.
public struct DevArtifactScanner: Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case node, target, python, build

        public var label: String {
            switch self {
            case .node: "node_modules"
            case .target: "target"
            case .python: "venv / Python"
            case .build: "Caches de build"
            }
        }
    }

    public var roots: [URL]
    public var now: Date
    /// Au-delà, le projet est « inactif » et ses artefacts sont cochés par défaut.
    public var inactiveAfter: TimeInterval = 90 * 86_400
    /// Dossiers de travail des processus en cours : ces projets sont verrouillés (règle n° 3).
    public var busyDirectories: [String]
    public var maxDepth = 8
    public var home: String

    public init(roots: [URL], busyDirectories: [String] = [], now: Date = .now, home: String = NSHomeDirectory()) {
        self.roots = roots
        self.busyDirectories = busyDirectories
        self.now = now
        self.home = home
    }

    struct Found: Hashable {
        let url: URL
        let kind: Kind
    }

    public func scan() async -> [CleanupGroup] {
        let found = roots.flatMap(walk).uniqued()
        let sizes = await DiskUsage.measure(found.map(\.url))

        var byProject: [URL: [Found]] = [:]
        for artifact in found { byProject[project(of: artifact.url), default: []].append(artifact) }

        var old: [CleanupItem] = []
        var recent: [CleanupItem] = []
        var busy: [CleanupItem] = []
        for (project, artifacts) in byProject {
            let entries = artifacts
                .map { CleanupItem.Entry(url: $0.url, bytes: sizes[$0.url]?.bytes ?? 0, kind: $0.kind.rawValue) }
                .filter { $0.bytes > 0 }
                .sorted { $0.bytes > $1.bytes }
            guard !entries.isEmpty else { continue }

            let names = Array(Set(artifacts.map { $0.url.lastPathComponent })).sorted()
            let shown = names.prefix(4).joined(separator: ", ") + (names.count > 4 ? "…" : "")
            let activity = lastActivity(of: project)
            let inactive = activity.map { now.timeIntervalSince($0) > inactiveAfter } ?? false
            let isBusy = busyDirectories.contains { $0 == project.path || $0.hasPrefix(project.path + "/") }

            var item = CleanupItem(
                id: project.path, name: project.lastPathComponent,
                detail: "\(project.abbreviatingHome(home)) · \(shown)", detailIsPath: true,
                meta: activity.map { RelativeDate.french($0, now: now) },
                metaHighlighted: inactive,
                tag: activity.map { now.timeIntervalSince($0) < 86_400 } == true ? "Actif" : nil,
                selectedByDefault: inactive, entries: entries
            )
            if isBusy {
                item.lockReason = "un processus tourne dans ce projet"
                item.risk = .protected
                item.tag = "En cours d’utilisation"
                item.selectedByDefault = false
                busy.append(item)
            } else if inactive {
                old.append(item)
            } else {
                recent.append(item)
            }
        }
        let bySize: (CleanupItem, CleanupItem) -> Bool = { $0.bytes > $1.bytes }
        return [
            CleanupGroup(id: "old", title: "Projets inactifs · plus de 3 mois", detail: "Proposés en priorité", items: old.sorted(by: bySize)),
            CleanupGroup(id: "recent", title: "Projets récents", detail: "Vous travaillez dessus : non cochés", tone: .neutral, items: recent.sorted(by: bySize)),
            CleanupGroup(id: "busy", title: "En cours d’utilisation", detail: "Un processus tourne dans ces projets : on n’y touche pas", tone: .neutral, items: busy.sorted(by: bySize)),
        ].filter { !$0.items.isEmpty }
    }

    // MARK: - Parcours

    private static let skipped: Set<String> = [
        ".git", ".hg", ".svn", "Library", "Applications", ".Trash", "Pods", "Carthage",
    ]
    private static let alwaysArtifacts: [String: Kind] = [
        "node_modules": .node,
        "__pycache__": .python, ".pytest_cache": .python, ".mypy_cache": .python, ".ruff_cache": .python, ".tox": .python,
        ".next": .build, ".nuxt": .build, ".turbo": .build, ".svelte-kit": .build, ".parcel-cache": .build,
        ".angular": .build, ".gradle": .build,
    ]

    func walk(_ root: URL) -> [Found] {
        var found: [Found] = []
        var stack: [(URL, Int)] = [(root, 0)]
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        while let (dir, depth) = stack.popLast() {
            if Task.isCancelled { break }
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys)) else { continue }
            for child in children {
                guard let values = try? child.resourceValues(forKeys: keys),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let name = child.lastPathComponent
                if let kind = Self.artifactKind(name: name, url: child, parent: dir) {
                    found.append(Found(url: child, kind: kind))
                } else if !name.hasPrefix("."), !Self.skipped.contains(name), depth < maxDepth {
                    stack.append((child, depth + 1))
                }
            }
        }
        return found
    }

    static func artifactKind(name: String, url: URL, parent: URL) -> Kind? {
        if let kind = alwaysArtifacts[name] { return kind }
        let fm = FileManager.default
        func sibling(_ file: String) -> Bool { fm.fileExists(atPath: parent.appendingPathComponent(file).path) }
        if name == "target", sibling("Cargo.toml") || sibling("pom.xml") || sibling("build.sbt") { return .target }
        if ["venv", ".venv", "env", ".env"].contains(name),
           fm.fileExists(atPath: url.appendingPathComponent("pyvenv.cfg").path) { return .python }
        if name == ".build", sibling("Package.swift") { return .build }
        return nil
    }

    // MARK: - Projets

    private static let markers = [
        "package.json", "Cargo.toml", "pom.xml", "build.gradle", "build.gradle.kts", "pyproject.toml",
        "requirements.txt", "setup.py", "Package.swift", "go.mod", "composer.json", "Gemfile", "build.sbt",
    ]

    /// Le dépôt git qui contient l'artefact, sinon le dossier le plus proche qui a l'air d'un projet.
    func project(of artifact: URL) -> URL {
        let fm = FileManager.default
        let rootPaths = Set(roots.map { $0.standardizedFileURL.path })
        var dir = artifact.deletingLastPathComponent().standardizedFileURL
        var nearestMarker: URL?
        while true {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir }
            if nearestMarker == nil, Self.markers.contains(where: { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) {
                nearestMarker = dir
            }
            let parent = dir.deletingLastPathComponent()
            if rootPaths.contains(dir.path) || parent.path == dir.path { break }
            dir = parent
        }
        return nearestMarker ?? artifact.deletingLastPathComponent()
    }

    /// Dernière activité : index git, ou fichiers du premier niveau (hors artefacts).
    func lastActivity(of project: URL) -> Date? {
        let fm = FileManager.default
        var candidates: [URL] = [".git/index", ".git/HEAD", ".git/FETCH_HEAD"].map { project.appendingPathComponent($0) }
        let children = (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        candidates += children.filter { child in
            let name = child.lastPathComponent
            return Self.artifactKind(name: name, url: child, parent: project) == nil && name != ".git" && name != ".DS_Store"
        }
        return candidates
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }

    /// Dossiers habituels de projets qui existent sur ce Mac.
    public static func defaultRoots(home: String = NSHomeDirectory()) -> [URL] {
        ["projects", "Projects", "Developer", "dev", "Dev", "code", "Code", "src", "work", "workspace",
         "repos", "git", "IdeaProjects", "Documents/GitHub", "Documents/Projects"]
            .map { URL(fileURLWithPath: home).appendingPathComponent($0) }
            .filter { url in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            }
            .uniquedByRealPath()
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

extension Array where Element == URL {
    /// Sur un disque insensible à la casse, ~/projects et ~/Projects sont le même dossier.
    func uniquedByRealPath() -> [URL] {
        var seen = Set<String>()
        return filter { url in
            let real = (try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? url.path
            return seen.insert(real.lowercased()).inserted
        }
    }
}
