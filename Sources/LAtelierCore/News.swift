import Foundation

// MARK: - Modèle

/// Rubrique d'une source de news.
public enum NewsCategory: String, Codable, Sendable, CaseIterable {
    case cyber, langage, general, personnel

    public var label: String {
        switch self {
        case .cyber: "Cyber"
        case .langage: "Langage"
        case .general: "Général"
        case .personnel: "Personnel"
        }
    }
}

/// Comment une source se lit.
public enum NewsFeedKind: String, Codable, Sendable {
    /// Flux RSS ou Atom.
    case feed
    /// API publique des avis GitHub (sans compte : 60 requêtes par heure).
    case githubAdvisories
    /// Catalogue CISA des vulnérabilités activement exploitées (JSON).
    case cisaKEV
}

public struct NewsSource: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var url: URL
    public var category: NewsCategory
    public var kind: NewsFeedKind
    /// Sujet des articles (« Rust »), `nil` : celui de la rubrique.
    public var topic: String?
    public var builtIn: Bool

    public init(id: String, name: String, url: URL, category: NewsCategory, kind: NewsFeedKind = .feed, topic: String? = nil, builtIn: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.category = category
        self.kind = kind
        self.topic = topic
        self.builtIn = builtIn
    }

    /// Adresse sans « https:// », pour l'affichage.
    public var displayURL: String {
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        return text
    }
}

/// Paquet touché par un avis (GitHub Advisories).
public struct AdvisoryPackage: Codable, Sendable, Hashable {
    /// Écosystème au sens de L’Atelier (`npm`, `cargo`…), ou nom brut de GitHub s'il n'est pas connu.
    public var ecosystem: String
    public var name: String
    /// « >= 1.8.14, < 3.3.3 »
    public var range: String?
    public var fixed: String?

    public init(ecosystem: String, name: String, range: String? = nil, fixed: String? = nil) {
        self.ecosystem = ecosystem
        self.name = name
        self.range = range
        self.fixed = fixed
    }
}

public struct NewsItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var sourceID: String
    public var title: String
    public var summary: String
    public var link: URL?
    public var date: Date
    /// Sujet affiché (« Rust », « Cyber »).
    public var topic: String
    public var category: NewsCategory
    /// Langage concerné par un avis (« JS / TS »), pour « Pour vous ».
    public var language: String?
    /// critical, high, moderate, low
    public var severity: String?
    public var cve: String?
    public var packages: [AdvisoryPackage] = []
    /// Produits cités par un avis (CISA KEV : éditeur, produit).
    public var products: [String] = []
    /// Faille activement exploitée (CISA KEV).
    public var exploited = false

    public init(id: String, sourceID: String, title: String, summary: String, link: URL?, date: Date, topic: String, category: NewsCategory) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.summary = summary
        self.link = link
        self.date = date
        self.topic = topic
        self.category = category
    }

    public var isCritical: Bool { severity == "critical" || exploited }
    public var isSevere: Bool { isCritical || severity == "high" }
}

// MARK: - Catalogue

public enum NewsCatalog {
    private static func source(_ id: String, _ name: String, _ url: String, _ category: NewsCategory, _ kind: NewsFeedKind = .feed, topic: String? = nil) -> NewsSource {
        NewsSource(id: id, name: name, url: URL(string: url)!, category: category, kind: kind, topic: topic)
    }

    /// Sources livrées avec l'app. Les sources de langage ne sont actives d'office que pour les sujets suivis.
    public static let builtIn: [NewsSource] = [
        source("gha", "GitHub Advisories", "https://api.github.com/advisories", .cyber, .githubAdvisories),
        source("kev", "CISA KEV", "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json", .cyber, .cisaKEV),
        source("certfr", "CERT-FR", "https://www.cert.cyber.gouv.fr/feed/", .cyber),
        source("nodesec", "Node.js · sécurité", "https://nodejs.org/en/feed/vulnerability.xml", .cyber, topic: "JS / TS"),
        source("rust", "Rust Blog", "https://blog.rust-lang.org/feed.xml", .langage, topic: "Rust"),
        source("go", "Go Blog", "https://go.dev/blog/feed.atom", .langage, topic: "Go"),
        source("python", "Python Insider", "https://blog.python.org/feeds/posts/default", .langage, topic: "Python"),
        source("node", "Node.js Blog", "https://nodejs.org/en/feed/blog.xml", .langage, topic: "JS / TS"),
        source("typescript", "TypeScript", "https://devblogs.microsoft.com/typescript/feed/", .langage, topic: "JS / TS"),
        source("deno", "Deno", "https://deno.com/feed", .langage, topic: "JS / TS"),
        source("bun", "Bun", "https://bun.sh/rss.xml", .langage, topic: "JS / TS"),
        source("swift", "Swift.org", "https://www.swift.org/atom.xml", .langage, topic: "Swift"),
        source("kotlin", "Kotlin Blog", "https://blog.jetbrains.com/kotlin/feed/", .langage, topic: "Kotlin"),
        source("java", "Inside Java", "https://inside.java/feed.xml", .langage, topic: "Java"),
        source("ruby", "Ruby", "https://www.ruby-lang.org/en/feeds/news.rss", .langage, topic: "Ruby"),
        source("php", "PHP", "https://www.php.net/feed.atom", .langage, topic: "PHP"),
        source("dotnet", ".NET Blog", "https://devblogs.microsoft.com/dotnet/feed/", .langage, topic: ".NET"),
        source("docker", "Docker Blog", "https://www.docker.com/blog/feed/", .langage, topic: "Docker"),
        source("postgres", "PostgreSQL", "https://www.postgresql.org/news.rss", .langage, topic: "PostgreSQL"),
        source("hn", "Hacker News", "https://news.ycombinator.com/rss", .general),
        source("lobsters", "Lobsters", "https://lobste.rs/rss", .general),
    ]

    /// Une source est active d'office si c'est un avis de sécurité, une source ajoutée à la main,
    /// ou un langage suivi. Les sources générales sont optionnelles.
    public static func enabledByDefault(_ source: NewsSource, topics: Set<String>) -> Bool {
        switch source.category {
        case .cyber, .personnel: true
        case .general: false
        case .langage: source.topic.map(topics.contains) ?? true
        }
    }
}

// MARK: - Sujets

/// Sujet suivi, et pourquoi (« 12 projets », « Homebrew »).
public struct NewsTopic: Sendable, Hashable, Identifiable {
    public var name: String
    public var reason: String?
    public var auto: Bool

    public var id: String { name }

    public init(name: String, reason: String? = nil, auto: Bool) {
        self.name = name
        self.reason = reason
        self.auto = auto
    }
}

public enum NewsTopics {
    public static func topic(for ecosystem: Ecosystem) -> String {
        switch ecosystem {
        case .npm: "JS / TS"
        case .cargo: "Rust"
        case .pypi: "Python"
        case .go: "Go"
        case .swift: "Swift"
        case .maven: "Java"
        case .packagist: "PHP"
        case .rubygems: "Ruby"
        }
    }

    /// Paquet installé → sujet (« postgresql@16 » → PostgreSQL).
    static func topic(forPackage name: String) -> String? {
        let base = name.lowercased().split(separator: "@").first.map(String.init) ?? name.lowercased()
        switch base {
        case "node", "deno", "bun", "typescript", "pnpm", "yarn": return "JS / TS"
        case "rust", "rustup", "rustup-init": return "Rust"
        case "python", "pipx", "uv", "poetry", "pyenv": return "Python"
        case "go": return "Go"
        case "openjdk", "maven", "gradle": return "Java"
        case "kotlin": return "Kotlin"
        case "ruby", "rbenv": return "Ruby"
        case "php", "composer": return "PHP"
        case "dotnet", "dotnet-sdk": return ".NET"
        case "docker", "docker-desktop", "orbstack", "colima", "podman": return "Docker"
        case "postgresql", "libpq", "postgres-app": return "PostgreSQL"
        default: return nil
        }
    }

    /// Sujets déduits des projets (écosystèmes des manifestes) et des paquets installés.
    public static func detect(manifests: [ProjectManifest], packages: [Package]) -> [NewsTopic] {
        var projects: [String: Set<String>] = [:]
        for manifest in manifests where !manifest.dependencies.isEmpty || manifest.ecosystem != .npm {
            projects[topic(for: manifest.ecosystem), default: []].insert(manifest.project.path)
        }
        var found: [String: String] = [:]
        for (topic, paths) in projects {
            found[topic] = "\(paths.count) projet\(paths.count > 1 ? "s" : "")"
        }
        for package in packages where package.onRequest || package.source == .runtimes {
            guard let topic = topic(forPackage: package.identifier) ?? topic(forPackage: package.name), found[topic] == nil else { continue }
            found[topic] = package.source.label
        }
        let order = ["JS / TS", "Python", "Rust", "Go", "Swift", "Java", "Kotlin", "Ruby", "PHP", ".NET", "Docker", "PostgreSQL"]
        return found
            .sorted { (order.firstIndex(of: $0.key) ?? 99, $0.key) < (order.firstIndex(of: $1.key) ?? 99, $1.key) }
            .map { NewsTopic(name: $0.key, reason: $0.value, auto: true) }
    }

    /// Un sujet ajouté à la main (« Kubernetes ») est cherché dans le titre et le résumé.
    public static func mentions(_ item: NewsItem, _ topic: String) -> Bool {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: topic) + "(?![\\p{L}\\p{N}])"
        return (item.title + " " + item.summary).range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

// MARK: - Croisement avec la machine

/// Ce qui est présent sur la machine : dépendances des projets et paquets installés.
public struct NewsInventory: Sendable {
    public struct Use: Sendable, Hashable {
        public var project: URL
        public var file: String
        public var version: String
        public var direct: Bool
    }

    public struct Installed: Sendable, Hashable {
        public var name: String
        public var identifier: String
        public var version: String
        public var source: PackageSource
        public var ecosystem: Ecosystem?
    }

    /// « npm:next » → usages
    public var dependencies: [String: [Use]] = [:]
    public var installed: [Installed] = []
    public var ecosystems: Set<Ecosystem> = []

    public init() {}

    public init(manifests: [ProjectManifest], packages: [Package]) {
        for manifest in manifests {
            ecosystems.insert(manifest.ecosystem)
            for dep in manifest.dependencies {
                dependencies["\(dep.ecosystem.rawValue):\(dep.name.lowercased())", default: []].append(
                    Use(project: manifest.project, file: manifest.lockfile ?? manifest.manifest, version: dep.version, direct: dep.direct)
                )
            }
        }
        installed = packages.map { package in
            let ecosystem: Ecosystem? = switch package.source {
            case .npm: .npm
            case .cargo: .cargo
            default: nil
            }
            return Installed(name: package.name, identifier: package.identifier, version: package.version, source: package.source, ecosystem: ecosystem)
        }
    }

    public var isEmpty: Bool { dependencies.isEmpty && installed.isEmpty }
}

/// Une news touche quelque chose sur la machine.
public struct NewsMatch: Sendable, Hashable, Identifiable {
    public var package: String
    public var version: String?
    /// Projet concerné (dépendance), `nil` pour un paquet installé.
    public var project: URL?
    /// « package-lock.json », « Homebrew »
    public var place: String
    public var fixed: String?
    /// Version dans l'intervalle vulnérable ; faux : le nom est cité, la version n'est pas vérifiable.
    public var confirmed: Bool
    public var direct: Bool
    public var source: PackageSource?

    public var id: String { "\(project?.path ?? place)|\(package)|\(version ?? "")" }
}

public enum NewsMatcher {
    /// Noms trop courants pour être cherchés dans un titre.
    static let ignoredNames: Set<String> = [
        "core", "server", "client", "base", "common", "tools", "utils", "make", "tree", "less", "file", "open", "data",
        "watch", "time", "test", "link", "mail", "zip", "unzip", "pass", "screen", "gettext", "readline", "ca-certificates",
        "pcre", "pcre2", "xz", "gmp", "mpfr", "isl", "lz4", "zstd", "jpeg", "libpng", "glib", "cairo", "pixman", "harfbuzz",
    ]

    public static func matches(_ item: NewsItem, in inventory: NewsInventory) -> [NewsMatch] {
        var found: [NewsMatch] = []
        // Avis avec paquets et intervalles : vérification de version.
        for package in item.packages {
            guard let ecosystem = Ecosystem(rawValue: package.ecosystem) else { continue }
            let uses = inventory.dependencies["\(ecosystem.rawValue):\(package.name.lowercased())"] ?? []
            for use in uses where VersionRange.contains(package.range, use.version) {
                found.append(NewsMatch(package: package.name, version: use.version, project: use.project, place: use.file,
                                       fixed: package.fixed, confirmed: true, direct: use.direct))
            }
            for installed in inventory.installed where installed.ecosystem == ecosystem
                && installed.identifier.lowercased() == package.name.lowercased()
                && VersionRange.contains(package.range, installed.version) {
                found.append(NewsMatch(package: package.name, version: installed.version, project: nil, place: installed.source.label,
                                       fixed: package.fixed, confirmed: true, direct: true, source: installed.source))
            }
        }
        // Avis de sécurité sans paquet structuré (CERT-FR, CISA KEV, Node) : nom cité dans le titre ou le produit.
        if item.category == .cyber && item.packages.isEmpty {
            let text = ([item.title] + item.products).joined(separator: " ")
            var seen: Set<String> = []
            for installed in inventory.installed where installed.ecosystem == nil {
                for candidate in names(of: installed) where !seen.contains(candidate) && mentions(text, candidate) {
                    seen.insert(candidate)
                    found.append(NewsMatch(package: installed.name, version: installed.version, project: nil, place: installed.source.label,
                                           fixed: nil, confirmed: false, direct: true, source: installed.source))
                    break
                }
            }
        }
        var unique: Set<String> = []
        return found.filter { unique.insert($0.id).inserted }
    }

    /// Noms cherchables d'un paquet : « openssl@3 » → openssl ; « Google Chrome » ; « node » → node, node.js.
    static func names(of installed: NewsInventory.Installed) -> [String] {
        var names: [String] = []
        let base = installed.identifier.lowercased().split(separator: "@").first.map(String.init) ?? installed.identifier.lowercased()
        if !ignoredNames.contains(base) && (base.count >= 4 || ["git", "php", "vim", "zsh", "go"].contains(base)) {
            names.append(base)
        }
        if base == "node" { names.append("node.js") }
        let display = installed.name.lowercased()
        if display != base, display.count >= 5, !ignoredNames.contains(display) { names.append(display) }
        return names
    }

    static func mentions(_ text: String, _ name: String) -> Bool {
        let pattern = "(?<![\\p{L}\\p{N}_-])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}_-])"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Intervalle de versions façon GitHub : « >= 1.8.14, < 3.3.3 », « = 2.0.0 », « <= 4.17.20 ».
public enum VersionRange {
    public static func contains(_ range: String?, _ version: String) -> Bool {
        guard let range, !range.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        let clean = { (v: String) in v.hasPrefix("v") ? String(v.dropFirst()) : v }
        let target = clean(version)
        guard target.first?.isNumber == true else { return false }
        for part in range.split(separator: ",") {
            let condition = part.trimmingCharacters(in: .whitespaces)
            let ops = [">=", "<=", ">", "<", "="]
            guard let op = ops.first(where: condition.hasPrefix) else { continue }
            let bound = clean(condition.dropFirst(op.count).trimmingCharacters(in: .whitespaces))
            let order = VersionOrder.compare(target, bound)
            let ok = switch op {
            case ">=": order != .orderedAscending
            case "<=": order != .orderedDescending
            case ">": order == .orderedDescending
            case "<": order == .orderedAscending
            default: order == .orderedSame
            }
            if !ok { return false }
        }
        return true
    }
}

// MARK: - Lecture des flux

/// Article lu dans un flux RSS ou Atom.
public struct FeedEntry: Sendable, Hashable {
    public var id: String
    public var title: String
    public var link: URL?
    public var date: Date?
    public var summary: String
}

public struct ParsedFeed: Sendable {
    public var title: String?
    /// « RSS » ou « Atom »
    public var format: String
    public var entries: [FeedEntry]
}

public enum FeedParser {
    public static func parse(_ data: Data) -> ParsedFeed? {
        let delegate = FeedXMLDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        _ = parser.parse()
        guard let format = delegate.format else { return nil }
        let entries = delegate.entries.map { raw in
            FeedEntry(
                id: raw.id ?? raw.link ?? raw.title,
                title: PlainText.plain(raw.title, limit: 300),
                link: raw.link.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) },
                date: raw.date.flatMap(FeedDate.parse),
                summary: PlainText.plain(raw.summary ?? "", limit: 600)
            )
        }
        .filter { !$0.title.isEmpty }
        return ParsedFeed(title: delegate.feedTitle.map { PlainText.plain($0, limit: 120) }, format: format, entries: entries)
    }
}

private final class FeedXMLDelegate: NSObject, XMLParserDelegate {
    struct Raw {
        var title = ""
        var link: String?
        var id: String?
        var date: String?
        var summary: String?
    }

    var format: String?
    var feedTitle: String?
    var entries: [Raw] = []
    private var current: Raw?
    private var text = ""
    private var depth = 0

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        text = ""
        switch name {
        case "rss", "rdf:RDF": format = format ?? "RSS"
        case "feed": format = format ?? "Atom"
        case "item", "entry": current = Raw()
        case "link" where current != nil:
            // Atom : <link rel="alternate" href="…"/> ; on garde le premier lien sans rel ou alternate.
            if let href = attributes["href"], current?.link == nil, attributes["rel"] == nil || attributes["rel"] == "alternate" {
                current?.link = href
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        text += String(data: block, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        depth -= 1
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }
        guard current != nil else {
            if name == "title", feedTitle == nil, !value.isEmpty { feedTitle = value }
            return
        }
        switch name {
        case "title": current?.title = value
        case "link" where !value.isEmpty && current?.link == nil: current?.link = value
        case "guid", "id": current?.id = value.isEmpty ? nil : value
        case "pubDate", "published", "dc:date", "updated":
            if current?.date == nil || name == "published" || name == "pubDate" { current?.date = value }
        case "description", "summary":
            if current?.summary?.isEmpty ?? true { current?.summary = value }
        case "content", "content:encoded":
            if current?.summary?.isEmpty ?? true { current?.summary = value }
        case "item", "entry":
            if let raw = current { entries.append(raw) }
            current = nil
        default: break
        }
    }
}

enum FeedDate {
    static func parse(_ text: String) -> Date? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z",
                       "EEE, dd MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

/// HTML ou Markdown → texte court lisible.
public enum PlainText {
    public static func plain(_ html: String, limit: Int) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<(script|style)[^>]*>[\\s\\S]*?</\\1>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<br\\s*/?>|</p>|</li>|</h\\d>", with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        // Markdown des avis GitHub : titres, emphase, code.
        text = text.replacingOccurrences(of: "(?m)^#{1,6}\\s*\\w[^\\n]*$", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "[*`]+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<end]) + "…"
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "rsquo": "’", "lsquo": "‘",
            "rdquo": "”", "ldquo": "“", "hellip": "…", "mdash": "—", "ndash": "–", "eacute": "é", "egrave": "è",
            "agrave": "à", "ccedil": "ç", "ecirc": "ê", "laquo": "«", "raquo": "»", "copy": "©",
        ]
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&", let semi = text[index...].prefix(10).firstIndex(of: ";") {
                let entity = String(text[text.index(after: index)..<semi])
                var replacement: String?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if entity.hasPrefix("#") {
                    replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    replacement = named[entity]
                }
                if let replacement {
                    result += replacement
                    index = text.index(after: semi)
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }
}

// MARK: - Avis structurés

public enum AdvisoryParser {
    /// Écosystème GitHub → écosystème L’Atelier.
    static func ecosystem(_ github: String) -> String {
        switch github {
        case "npm": "npm"
        case "pip": "pypi"
        case "rust": "cargo"
        case "go": "go"
        case "maven": "maven"
        case "composer": "packagist"
        case "rubygems": "rubygems"
        case "swift": "swift"
        default: github
        }
    }

    /// Réponse de `api.github.com/advisories`.
    public static func github(_ data: Data, sourceID: String = "gha") -> [NewsItem]? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        return list.compactMap { object in
            guard let ghsa = object["ghsa_id"] as? String, let title = object["summary"] as? String else { return nil }
            let date = (object["published_at"] as? String).flatMap(iso.date(from:)) ?? .now
            var item = NewsItem(
                id: "\(sourceID)|\(ghsa)", sourceID: sourceID, title: title,
                summary: PlainText.plain(object["description"] as? String ?? "", limit: 600),
                link: (object["html_url"] as? String).flatMap(URL.init(string:)), date: date, topic: "Cyber", category: .cyber
            )
            item.severity = object["severity"] as? String
            item.cve = object["cve_id"] as? String
            item.packages = (object["vulnerabilities"] as? [[String: Any]] ?? []).compactMap { vuln in
                guard let package = vuln["package"] as? [String: Any], let name = package["name"] as? String,
                      let eco = package["ecosystem"] as? String else { return nil }
                return AdvisoryPackage(ecosystem: ecosystem(eco), name: name,
                                       range: vuln["vulnerable_version_range"] as? String,
                                       fixed: vuln["first_patched_version"] as? String)
            }
            if let first = item.packages.first, let eco = Ecosystem(rawValue: first.ecosystem) {
                item.language = NewsTopics.topic(for: eco)
            }
            return item
        }
    }

    /// Catalogue CISA KEV : les ajouts des `days` derniers jours.
    public static func kev(_ data: Data, sourceID: String = "kev", days: Int = 45, now: Date = .now) -> [NewsItem]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["vulnerabilities"] as? [[String: Any]] else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let limit = now.addingTimeInterval(-Double(days) * 86_400)
        return list.compactMap { entry -> NewsItem? in
            guard let cve = entry["cveID"] as? String, let added = (entry["dateAdded"] as? String).flatMap(formatter.date(from:)),
                  added >= limit else { return nil }
            let vendor = entry["vendorProject"] as? String ?? ""
            let product = entry["product"] as? String ?? ""
            var item = NewsItem(
                id: "\(sourceID)|\(cve)", sourceID: sourceID,
                title: (entry["vulnerabilityName"] as? String) ?? "\(vendor) \(product)",
                summary: PlainText.plain(entry["shortDescription"] as? String ?? "", limit: 600),
                link: URL(string: "https://nvd.nist.gov/vuln/detail/\(cve)"), date: added, topic: "Cyber", category: .cyber
            )
            item.cve = cve
            item.exploited = true
            item.severity = "high"
            item.products = [vendor, product].filter { !$0.isEmpty }
            return item
        }
        .sorted { $0.date > $1.date }
    }
}

// MARK: - Réseau

/// Lit les sources. Seules des requêtes GET vers les adresses des sources sortent de la machine (règle n° 7).
public struct NewsFetcher: Sendable {
    public struct Outcome: Sendable {
        public var sourceID: String
        public var items: [NewsItem]
        public var error: String?
        public var format: String?
        public var title: String?
    }

    public enum FetchError: LocalizedError {
        case http(Int)
        case unreadable
        case network(String)

        public var errorDescription: String? {
            switch self {
            case .http(403), .http(429): "Limite de requêtes atteinte"
            case .http(let code): "Erreur \(code)"
            case .unreadable: "Format non reconnu"
            case .network(let text): text
            }
        }
    }

    /// Articles gardés par flux.
    public static let perFeed = 25
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Lit toutes les sources en parallèle (6 à la fois).
    public func fetch(_ sources: [NewsSource], ecosystems: Set<Ecosystem>) async -> [Outcome] {
        await withTaskGroup(of: Outcome.self) { group in
            var iterator = sources.makeIterator()
            func next() -> Bool {
                guard let source = iterator.next() else { return false }
                group.addTask { await fetch(source, ecosystems: ecosystems) }
                return true
            }
            for _ in 0..<6 where next() {}
            var outcomes: [Outcome] = []
            while let outcome = await group.next() {
                outcomes.append(outcome)
                _ = next()
            }
            return outcomes
        }
    }

    public func fetch(_ source: NewsSource, ecosystems: Set<Ecosystem>) async -> Outcome {
        do {
            switch source.kind {
            case .feed:
                let feed = try await readFeed(source.url)
                let items = feed.entries.prefix(Self.perFeed).map { entry in
                    var item = NewsItem(
                        id: "\(source.id)|\(entry.id)", sourceID: source.id, title: entry.title, summary: entry.summary,
                        link: entry.link, date: entry.date ?? .now,
                        topic: source.category == .cyber ? "Cyber" : (source.topic ?? source.category.label), category: source.category
                    )
                    item.language = source.topic
                    return item
                }
                return Outcome(sourceID: source.id, items: Array(items), format: feed.format, title: feed.title)
            case .githubAdvisories:
                // Liste générale (les plus récents), puis un appel par écosystème utilisé ici pour le croisement.
                var items: [String: NewsItem] = [:]
                var urls = [Self.advisoriesURL(source.url, ecosystem: nil)]
                let names: [Ecosystem: String] = [.npm: "npm", .pypi: "pip", .cargo: "rust", .go: "go", .maven: "maven",
                                                  .packagist: "composer", .rubygems: "rubygems", .swift: "swift"]
                urls += ecosystems.sorted { $0.rawValue < $1.rawValue }.compactMap { names[$0].map { Self.advisoriesURL(source.url, ecosystem: $0) } }
                var firstError: Error?
                for url in urls {
                    do {
                        let data = try await get(url, accept: "application/vnd.github+json")
                        guard let parsed = AdvisoryParser.github(data, sourceID: source.id) else { throw FetchError.unreadable }
                        for item in parsed { items[item.id] = item }
                    } catch {
                        firstError = firstError ?? error
                        if case FetchError.http(let code) = error, code == 403 || code == 429 { break }
                    }
                }
                if items.isEmpty, let firstError { throw firstError }
                return Outcome(sourceID: source.id, items: items.values.sorted { $0.date > $1.date }, error: firstError?.localizedDescription, format: "API")
            case .cisaKEV:
                let data = try await get(source.url)
                guard let items = AdvisoryParser.kev(data, sourceID: source.id) else { throw FetchError.unreadable }
                return Outcome(sourceID: source.id, items: items, format: "JSON")
            }
        } catch {
            return Outcome(sourceID: source.id, items: [], error: Self.describe(error))
        }
    }

    static func advisoriesURL(_ base: URL, ecosystem: String?) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "type", value: "reviewed"), URLQueryItem(name: "per_page", value: "100")]
            + (ecosystem.map { [URLQueryItem(name: "ecosystem", value: $0)] } ?? [])
        return components.url!
    }

    /// Lit un flux ajouté à la main avant de l'enregistrer.
    public func probe(_ url: URL) async throws -> ParsedFeed {
        try await readFeed(url)
    }

    private func readFeed(_ url: URL) async throws -> ParsedFeed {
        let data = try await get(url)
        guard let feed = FeedParser.parse(data) else { throw FetchError.unreadable }
        return feed
    }

    private func get(_ url: URL, accept: String? = nil) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("LAtelier (macOS)", forHTTPHeaderField: "User-Agent")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FetchError.network(Self.describe(error))
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw FetchError.http(http.statusCode) }
        return data
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? FetchError { return error.localizedDescription }
        let code = (error as? URLError)?.code
        return switch code {
        case .timedOut: "Délai dépassé"
        case .notConnectedToInternet, .networkConnectionLost: "Pas de connexion"
        case .cannotFindHost, .dnsLookupFailed: "Adresse introuvable"
        case .secureConnectionFailed, .serverCertificateUntrusted: "Connexion sécurisée impossible"
        default: error.localizedDescription
        }
    }
}

// MARK: - État gardé sur le Mac

public struct NewsSourceStatus: Codable, Sendable, Hashable {
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var error: String?
    public var format: String?
    public var count = 0

    public init() {}
}

/// Articles, lus, favoris, sources ajoutées, sujets : `news.json` dans Application Support.
public struct NewsState: Codable, Sendable {
    public var items: [NewsItem] = []
    public var read: Set<String> = []
    public var starred: Set<String> = []
    /// Source activée ou désactivée à la main ; sinon `NewsCatalog.enabledByDefault`.
    public var overrides: [String: Bool] = [:]
    public var custom: [NewsSource] = []
    public var manualTopics: [String] = []
    /// Sujets automatiques retirés.
    public var hiddenTopics: Set<String> = []
    public var status: [String: NewsSourceStatus] = [:]
    public var lastRefresh: Date?
    /// Alertes déjà notifiées.
    public var notified: Set<String> = []

    public init() {}

    /// Ajoute les articles lus, sans doublon ; garde 60 jours (les favoris toujours) et 1 500 articles au plus.
    public mutating func merge(_ fresh: [NewsItem], now: Date = .now) -> [NewsItem] {
        var byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var added: [NewsItem] = []
        for item in fresh {
            if byID[item.id] == nil { added.append(item) }
            byID[item.id] = item
        }
        let limit = now.addingTimeInterval(-60 * 86_400)
        items = byID.values
            .filter { $0.date >= limit || starred.contains($0.id) }
            .sorted { $0.date > $1.date }
        if items.count > 1_500 {
            let keep = Set(items.prefix(1_500).map(\.id)).union(starred)
            items = items.filter { keep.contains($0.id) }
        }
        let ids = Set(items.map(\.id))
        read = read.intersection(ids)
        notified = notified.intersection(ids)
        return added
    }
}
