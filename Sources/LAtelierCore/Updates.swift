import Foundation

/// Une version publiée sur GitHub (Releases).
public struct AppRelease: Sendable, Equatable {
    public var version: String
    public var tag: String
    public var notes: String
    public var published: Date?
    public var page: URL?
    /// Image disque à télécharger, et son empreinte SHA-256 (fichier `.sha256` publié à côté).
    public var dmg: URL?
    public var checksum: URL?

    public init(version: String, tag: String, notes: String = "", published: Date? = nil, page: URL? = nil, dmg: URL? = nil, checksum: URL? = nil) {
        self.version = version
        self.tag = tag
        self.notes = notes
        self.published = published
        self.page = page
        self.dmg = dmg
        self.checksum = checksum
    }
}

/// Vérification des mises à jour : une seule requête vers l'API publique de GitHub,
/// sans rien envoyer d'autre que le nom du dépôt.
public enum UpdateChecker {
    public static func latestURL(repository: String) -> URL? {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    }

    public static func parse(_ data: Data) -> AppRelease? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        if json["draft"] as? Bool == true || json["prerelease"] as? Bool == true { return nil }
        let assets = (json["assets"] as? [[String: Any]]) ?? []
        func asset(_ suffix: String) -> URL? {
            assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(suffix) == true }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }
        return AppRelease(
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
            tag: tag,
            notes: json["body"] as? String ?? "",
            published: (json["published_at"] as? String).flatMap { try? Date($0, strategy: .iso8601) },
            page: (json["html_url"] as? String).flatMap(URL.init(string:)),
            dmg: asset(".dmg"),
            checksum: asset(".dmg.sha256")
        )
    }

    /// `0.10.0` > `0.9.2` ; les suffixes (`-beta`) passent après la version simple.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> ([Int], String) {
            let split = version.split(separator: "-", maxSplits: 1)
            let numbers = split[0].split(separator: ".").map { Int($0) ?? 0 }
            return (numbers, split.count > 1 ? String(split[1]) : "")
        }
        let (a, suffixA) = parts(candidate)
        let (b, suffixB) = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        if suffixA.isEmpty != suffixB.isEmpty { return suffixA.isEmpty }
        return suffixA > suffixB
    }

    /// Première empreinte SHA-256 trouvée dans un fichier `.sha256` (`<hex>  fichier.dmg`).
    public static func checksum(in text: String) -> String? {
        text.split(whereSeparator: { $0.isWhitespace }).first { $0.count == 64 && $0.allSatisfy(\.isHexDigit) }.map { $0.lowercased() }
    }
}

/// Étapes d'une mise à jour, montrées dans l'aperçu puis exécutées une à une.
public enum UpdatePlanner {
    /// Depuis l'image disque publiée : téléchargement, empreinte, signature (même certificat
    /// que la version installée), puis remplacement. L'ancienne version va à la corbeille.
    public static func fromRelease(
        _ release: AppRelease, dmg: URL, sha256: String, installed: URL, requirement: String?, work: URL
    ) -> [ActionStep] {
        let file = work.appendingPathComponent("LAtelier-\(release.version).dmg")
        let mount = work.appendingPathComponent("volume")
        let staged = work.appendingPathComponent(installed.lastPathComponent)
        let mounted = mount.appendingPathComponent(installed.lastPathComponent)
        var steps: [ActionStep] = [
            .command(CommandSpec("/usr/bin/curl", ["--fail", "--location", "--silent", "--show-error", "--output", file.path, dmg.absoluteString])),
            .command(CommandSpec("/bin/sh", ["-c", "echo \(ShellQuote.quote("\(sha256)  \(file.path)")) | /usr/bin/shasum -a 256 -c"])),
            .command(CommandSpec("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, file.path])),
        ]
        var verify = ["--verify", "--deep", "--strict"]
        if let requirement { verify += ["-R=\(requirement)"] }
        steps.append(.command(CommandSpec("/usr/bin/codesign", verify + [mounted.path])))
        steps.append(.command(CommandSpec("/usr/bin/ditto", [mounted.path, staged.path])))
        steps.append(.command(CommandSpec("/usr/bin/hdiutil", ["detach", mount.path])))
        steps += swap(installed: installed, staged: staged)
        return steps
    }

    /// Depuis les sources (installation par install.sh) : le tag de la version, compilé sur ce Mac.
    public static func fromSource(_ release: AppRelease, source: URL, installed: URL, work: URL) -> [ActionStep] {
        let staged = work.appendingPathComponent(installed.lastPathComponent)
        let built = source.appendingPathComponent("build").appendingPathComponent(installed.lastPathComponent)
        var steps: [ActionStep] = [
            .command(CommandSpec("git", ["-C", source.path, "fetch", "--tags", "--force", "origin"])),
            .command(CommandSpec("git", ["-C", source.path, "checkout", "--detach", release.tag])),
            .command(CommandSpec("/usr/bin/make", ["-C", source.path, "app"], environment: ["SOURCE_INSTALL": "1"])),
            .command(CommandSpec("/usr/bin/ditto", [built.path, staged.path])),
        ]
        steps += swap(installed: installed, staged: staged)
        return steps
    }

    private static func swap(installed: URL, staged: URL) -> [ActionStep] {
        [
            .remove(installed, bytes: 0, permanently: false),
            // Jamais dans un dossier existant (mv y rangerait la nouvelle version) : seulement si la place est libre.
            .command(CommandSpec("/bin/sh", ["-c", "[ ! -e \(ShellQuote.quote(installed.path)) ] && /bin/mv \(ShellQuote.quote(staged.path)) \(ShellQuote.quote(installed.path))"])),
        ]
    }
}
