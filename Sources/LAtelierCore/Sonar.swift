import CoreServices
import CryptoKit
import Foundation

/// Stockage › Sonar : les gros fichiers personnels, leur ancienneté et pourquoi ils sont proposés.
public struct SonarFile: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case video, image, audio, archive, installer, document, vm

        public var label: String {
            switch self {
            case .video: String(localized: "Vidéos")
            case .image: "Images"
            case .audio: "Audio"
            case .archive: "Archives"
            case .installer: String(localized: "Installeurs et images disque")
            case .document: "Documents"
            case .vm: String(localized: "Machines virtuelles")
            }
        }
    }

    public var url: URL
    public var bytes: Int64
    public var kind: Kind
    /// Dernière ouverture (Spotlight), sinon `nil`.
    public var lastUsed: Date?
    public var created: Date?
    public var modified: Date?
    public var zone: SonarZone
    /// Autre fichier identique (empreinte égale).
    public var duplicateOf: URL?
    /// Installeur d'une app déjà présente.
    public var installedApp: String?

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    /// Date de référence pour l'ancienneté : dernière ouverture, sinon création / modification.
    public var reference: Date? { lastUsed ?? created ?? modified }

    public func ageDays(now: Date = .now) -> Int {
        guard let reference else { return 0 }
        return max(0, Int(now.timeIntervalSince(reference) / 86_400))
    }

    /// Pourquoi ce fichier est proposé.
    public func reason(now: Date = .now) -> String {
        let days = ageDays(now: now)
        if let original = duplicateOf { return String(localized: "Doublon exact de « \(original.lastPathComponent) » (\(original.deletingLastPathComponent().abbreviatingHome())).") }
        if let app = installedApp { return String(localized: "Installeur déjà utilisé : \(app) est installée.") }
        if days < 30, lastUsed != nil { return String(localized: "Ouvert récemment : sans doute encore utile.") }
        if lastUsed == nil, days >= 30 {
            return zone == .downloads ? String(localized: "Téléchargé \(Self.ago(days)) et jamais ouvert.") : String(localized: "Jamais ouvert depuis sa création (\(Self.ago(days))).")
        }
        if kind == .installer { return String(localized: "Image disque ou installeur ouvert \(Self.ago(days)) : l’installation est sans doute faite.") }
        if kind == .vm { return String(localized: "Machine virtuelle pas démarrée depuis \(Self.ago(days, prefix: false)).") }
        if days >= 365 { return String(localized: "Pas ouvert depuis \(Self.ago(days, prefix: false)).") }
        return String(localized: "Gros fichier ouvert \(Self.ago(days)).")
    }

    static func ago(_ days: Int, prefix: Bool = true) -> String {
        let text: String
        if days < 60 { text = "\(days) j" } else if days < 365 { text = "\(days / 30) mois" } else {
            let years = Double(days) / 365
            text = years < 2 ? String(format: "%.1f an", years).replacingOccurrences(of: ".", with: ",") : "\(Int(years)) ans"
        }
        return prefix ? String(localized: "il y a \(text)") : text
    }
}

public enum SonarZone: String, Sendable, CaseIterable {
    case home, downloads, documents, desktop, movies, music, pictures

    public var label: String {
        switch self {
        case .home: String(localized: "Dossier personnel")
        case .downloads: String(localized: "Téléchargements")
        case .documents: "Documents"
        case .desktop: String(localized: "Bureau")
        case .movies: String(localized: "Vidéos")
        case .music: String(localized: "Musique")
        case .pictures: "Images"
        }
    }

    public var folder: String? {
        switch self {
        case .home: nil
        case .downloads: "Downloads"
        case .documents: "Documents"
        case .desktop: "Desktop"
        case .movies: "Movies"
        case .music: "Music"
        case .pictures: "Pictures"
        }
    }

    /// Bureau, Documents, Téléchargements : autorisation de macOS.
    public var isPersonal: Bool { self == .downloads || self == .documents || self == .desktop }
}

public struct SonarScanner: Sendable {
    public var home: URL
    public var allowPersonal: Bool
    /// Taille minimale d'un fichier proposé.
    public var minimumBytes: Int64
    /// Dossiers jamais parcourus (projets : gérés par Développement).
    public var excluded: [URL]
    /// Noms des apps installées (minuscules), pour reconnaître un installeur déjà utilisé.
    public var installedApps: Set<String>

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), allowPersonal: Bool, minimumBytes: Int64 = 50_000_000,
                excluded: [URL] = [], installedApps: Set<String> = []) {
        self.home = home
        self.allowPersonal = allowPersonal
        self.minimumBytes = minimumBytes
        self.excluded = excluded
        self.installedApps = installedApps
    }

    static let extensions: [String: SonarFile.Kind] = {
        var map: [String: SonarFile.Kind] = [:]
        for e in ["mov", "mp4", "m4v", "mkv", "avi", "webm", "wmv", "flv", "mts", "m2ts", "3gp", "mpg", "mpeg"] { map[e] = .video }
        for e in ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "raw", "cr2", "cr3", "nef", "arw", "dng", "psd", "psb", "webp", "bmp", "exr"] { map[e] = .image }
        for e in ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "alac", "caf", "logicx", "band"] { map[e] = .audio }
        for e in ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst"] { map[e] = .archive }
        for e in ["dmg", "pkg", "mpkg", "iso", "xip", "img", "exe", "msi", "apk", "ipa"] { map[e] = .installer }
        for e in ["vdi", "vmdk", "vhd", "vhdx", "qcow2", "utm", "vmwarevm", "pvm", "hdd", "ova", "ovf"] { map[e] = .vm }
        for e in ["pdf", "key", "pages", "numbers", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "csv", "json", "sqlite", "db", "log", "txt", "epub", "ai", "sketch", "fig", "blend", "fbx", "obj", "glb"] { map[e] = .document }
        return map
    }()

    /// Paquets traités comme un seul fichier (machines virtuelles, bibliothèques).
    static let bundles: Set<String> = ["utm", "vmwarevm", "pvm", "logicx", "band", "photoslibrary", "musiclibrary", "app", "fcpbundle", "imovielibrary", "tvlibrary"]

    public static func kind(of url: URL) -> SonarFile.Kind {
        extensions[url.pathExtension.lowercased()] ?? .document
    }

    /// Dossiers parcourus pour une zone. « Dossier personnel » : les zones connues
    /// et les autres dossiers visibles du dossier personnel (sauf Library, Applications et les projets).
    public func roots(_ zone: SonarZone) -> [(URL, SonarZone)] {
        let all: [SonarZone] = zone == .home ? SonarZone.allCases.filter { $0 != .home } : [zone]
        var roots: [(URL, SonarZone)] = all.filter { allowPersonal || !$0.isPersonal }.compactMap { zone in
            zone.folder.map { (home.appending(path: $0), zone) }
        }
        if zone == .home {
            let known = Set(SonarZone.allCases.compactMap(\.folder) + ["Library", "Applications", "Public"])
            let excludedPaths = Set(excluded.map(\.standardizedFileURL.path))
            let others = ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? [])
                .filter { !$0.hasPrefix(".") && !known.contains($0) }
                .map { home.appending(path: $0) }
                .filter { url in
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
                        && !excludedPaths.contains(url.standardizedFileURL.path)
                }
            roots += others.map { ($0, .home) }
        }
        return roots
    }

    /// Parcourt une zone et rend les gros fichiers, doublons et installeurs reconnus.
    public func scan(_ zone: SonarZone) async -> [SonarFile] {
        let skip = PrivacyZones.skipped(allowPersonal: allowPersonal, home: home.path).union(excluded.map(\.path))
        var files: [SonarFile] = []
        for (root, rootZone) in roots(zone) {
            files += await Task.detached { collect(root, zone: rootZone, skip: skip) }.value
        }
        markDuplicates(&files)
        return files.sorted { $0.bytes > $1.bytes }
    }

    func collect(_ root: URL, zone: SonarZone, skip: Set<String>) -> [SonarFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                      .creationDateKey, .contentModificationDateKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return [] }
        var found: [SonarFile] = []
        var counter = 0
        for case let url as URL in enumerator {
            counter += 1
            if counter % 4096 == 0, Task.isCancelled { break }
            if skip.contains(url.path) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            let ext = url.pathExtension.lowercased()
            var bytes: Int64
            if values.isDirectory == true {
                // Projets de code : gérés par Développement. Paquets : un seul élément.
                if FileManager.default.fileExists(atPath: url.appending(path: ".git").path) {
                    enumerator.skipDescendants()
                    continue
                }
                guard Self.bundles.contains(ext) else { continue }
                enumerator.skipDescendants()
                // Bibliothèques Photos / Musique et apps : jamais proposées.
                if ["photoslibrary", "musiclibrary", "app", "tvlibrary"].contains(ext) { continue }
                bytes = DiskUsage.measure(url).bytes
            } else {
                bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
            guard bytes >= minimumBytes else { continue }
            var file = SonarFile(url: url, bytes: bytes, kind: Self.kind(of: url), lastUsed: AppInventory.lastUsed(url),
                                 created: values.creationDate, modified: values.contentModificationDate, zone: zone)
            if file.kind == .installer { file.installedApp = matchInstalledApp(url) }
            found.append(file)
        }
        return found
    }

    /// « Docker.dmg » → Docker si Docker.app est installée.
    func matchInstalledApp(_ url: URL) -> String? {
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
        let words = base.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 3 }
        guard let first = words.first else { return nil }
        let candidates = [words.prefix(2).joined(separator: " "), first]
        for candidate in candidates where installedApps.contains(candidate) {
            return candidate.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        return nil
    }

    /// Doublons : même taille, puis même empreinte SHA-256. Le plus ancien est gardé comme original.
    func markDuplicates(_ files: inout [SonarFile]) {
        let bySize = Dictionary(grouping: files.indices.filter { files[$0].bytes > 0 && !Self.bundles.contains(files[$0].url.pathExtension.lowercased()) },
                                by: { files[$0].bytes })
        for (_, indices) in bySize where indices.count > 1 {
            var byHash: [String: [Int]] = [:]
            for index in indices {
                if let hash = Self.hash(files[index].url) { byHash[hash, default: []].append(index) }
            }
            for (_, same) in byHash where same.count > 1 {
                let sorted = same.sorted { (files[$0].created ?? .distantFuture) < (files[$1].created ?? .distantFuture) }
                for index in sorted.dropFirst() { files[index].duplicateOf = files[sorted[0]].url }
            }
        }
    }

    static func hash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Position d'un fichier sur le radar.
public enum SonarRadar {
    /// Distance au centre (0…1) : logarithme de l'ancienneté, 3 ans et plus au bord.
    public static func radius(ageDays: Int) -> Double {
        max(0.12, min(0.94, log(Double(ageDays) + 1) / log(1100) * 0.94))
    }

    /// Angle en degrés : chaque type a son secteur, les fichiers s'y répartissent.
    public static func angle(kind: SonarFile.Kind, slot: Int) -> Double {
        let index = Double(SonarFile.Kind.allCases.firstIndex(of: kind) ?? 0)
        let sector = 360.0 / Double(SonarFile.Kind.allCases.count)
        return index * sector + 6 + Double((slot * 37) % Int(sector - 12))
    }
}

/// Filtres du Sonar.
public enum SonarLens: String, Sendable, CaseIterable {
    case all, old, big, duplicates, downloads

    public var label: String {
        switch self {
        case .all: String(localized: "Tout")
        case .old: String(localized: "Plus d’un an")
        case .big: String(localized: "Plus d’1 Go")
        case .duplicates: String(localized: "Doublons")
        case .downloads: String(localized: "Téléchargements oubliés")
        }
    }

    public func matches(_ file: SonarFile, now: Date = .now) -> Bool {
        switch self {
        case .all: true
        case .old: file.ageDays(now: now) >= 365
        case .big: file.bytes >= 1_000_000_000
        case .duplicates: file.duplicateOf != nil
        case .downloads: file.zone == .downloads && file.ageDays(now: now) >= 90
        }
    }
}
