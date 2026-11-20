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
              let tag = json["tag_name"] as? String, isValidVersion(tag) else { return nil }
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

    /// `1.0.0`, `v1.0.0-beta.2` : rien d'autre (un tag reçu de GitHub ne doit pas devenir une option ou un chemin).
    public static func isValidVersion(_ value: String) -> Bool {
        value.range(of: #"^v?[0-9]+(\.[0-9]+){0,3}(-[A-Za-z0-9]+(\.[A-Za-z0-9]+)*)?$"#, options: .regularExpression) != nil
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
        // « beta.10 » après « beta.9 » : les parties numériques se comparent comme des nombres.
        let partsA = suffixA.split(separator: "."), partsB = suffixB.split(separator: ".")
        for (x, y) in zip(partsA, partsB) where x != y {
            if let a = Int(x), let b = Int(y) { return a > b }
            return x > y
        }
        return partsA.count > partsB.count
    }

    /// Première empreinte SHA-256 trouvée dans un fichier `.sha256` (`<hex>  fichier.dmg`).
    public static func checksum(in text: String) -> String? {
        text.split(whereSeparator: { $0.isWhitespace }).first { $0.count == 64 && $0.allSatisfy(\.isHexDigit) }.map { $0.lowercased() }
    }
}

/// Étapes d'une mise à jour, montrées dans l'aperçu puis exécutées une à une.
/// La nouvelle version est préparée à côté de l'actuelle, vérifiée, puis échangée ; si l'échange
/// échoue, l'ancienne est remise en place. Elle ne part à la corbeille qu'une fois la nouvelle installée.
public enum UpdatePlanner {
    /// Depuis l'image disque publiée : téléchargement, empreinte SHA-256, copie, signature
    /// (même certificat que la version installée, obligatoire), puis échange.
    public static func fromRelease(
        _ release: AppRelease, dmg: URL, sha256: String, installed: URL, requirement: String, work: URL
    ) -> [ActionStep]? {
        guard UpdateChecker.isValidVersion(release.version), sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else { return nil }
        let file = work.appendingPathComponent("LAtelier-\(release.version).dmg")
        let mount = work.appendingPathComponent("volume")
        let (staged, old) = neighbours(of: installed)
        let mounted = mount.appendingPathComponent(installed.lastPathComponent)
        let q = ShellQuote.quote
        return [
            .command(CommandSpec("/usr/bin/curl", ["--fail", "--location", "--silent", "--show-error", "--proto", "=https,file", "--output", file.path, dmg.absoluteString])),
            .command(CommandSpec("/bin/sh", ["-c", "echo \(q("\(sha256)  \(file.path)")) | /usr/bin/shasum -a 256 -c"])),
            // Monter, copier, démonter : le démontage a lieu même si la copie échoue.
            .command(CommandSpec("/bin/sh", ["-c", "/usr/bin/hdiutil attach -nobrowse -readonly -noautoopen -mountpoint \(q(mount.path)) \(q(file.path)) >/dev/null && { /usr/bin/ditto \(q(mounted.path)) \(q(staged.path)); s=$?; /usr/bin/hdiutil detach \(q(mount.path)) -quiet; exit $s; }"])),
            .command(CommandSpec("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(requirement)", staged.path])),
        ] + swap(installed: installed, staged: staged, old: old)
    }

    /// Depuis les sources (installation par install.sh) : le tag de la version, compilé sur ce Mac.
    public static func fromSource(_ release: AppRelease, source: URL, installed: URL, requirement: String?) -> [ActionStep]? {
        guard UpdateChecker.isValidVersion(release.version), UpdateChecker.isValidVersion(release.tag) else { return nil }
        let (staged, old) = neighbours(of: installed)
        let built = source.appendingPathComponent("build").appendingPathComponent(installed.lastPathComponent)
        var steps: [ActionStep] = [
            .command(CommandSpec("git", ["-C", source.path, "fetch", "--tags", "--force", "origin"])),
            .command(CommandSpec("git", ["-C", source.path, "checkout", "--detach", "refs/tags/\(release.tag)"])),
            .command(CommandSpec("/usr/bin/make", ["-C", source.path, "app"], environment: ["SOURCE_INSTALL": "1"])),
            .command(CommandSpec("/usr/bin/ditto", [built.path, staged.path])),
        ]
        if let requirement {
            steps.append(.command(CommandSpec("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(requirement)", staged.path])))
        }
        return steps + swap(installed: installed, staged: staged, old: old)
    }

    /// Nouvelle version et ancienne, dans le même dossier que l'app (renommages instantanés, même volume).
    static func neighbours(of installed: URL) -> (staged: URL, old: URL) {
        let folder = installed.deletingLastPathComponent()
        let name = installed.deletingPathExtension().lastPathComponent
        return (folder.appendingPathComponent("\(name) (nouvelle version).app"),
                folder.appendingPathComponent("\(name) (ancienne version).app"))
    }

    private static func swap(installed: URL, staged: URL, old: URL) -> [ActionStep] {
        let q = ShellQuote.quote
        return [
            // Échange : en cas d'échec, l'ancienne version reprend sa place.
            .command(CommandSpec("/bin/sh", ["-c", "[ ! -e \(q(old.path)) ] && /bin/mv \(q(installed.path)) \(q(old.path)) && { /bin/mv \(q(staged.path)) \(q(installed.path)) || { /bin/mv \(q(old.path)) \(q(installed.path)); exit 1; }; }"])),
            .remove(old, bytes: 0, permanently: false),
        ]
    }
}
