import Foundation
import Testing
@testable import LAtelierCore

@Suite struct NewsFeedTests {
    @Test func rss() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel>
        <title>CERT-FR</title>
        <item><title>Multiples vulnérabilités dans OpenSSL (19 novembre 2026)</title>
        <link>https://www.cert.cyber.gouv.fr/avis/CERTFR-2026-AVI-1500/</link>
        <guid isPermaLink="true">https://www.cert.cyber.gouv.fr/avis/CERTFR-2026-AVI-1500/</guid>
        <description><![CDATA[<p>De multiples vulnérabilités ont été découvertes&nbsp;dans <b>OpenSSL</b>.</p>]]></description>
        <pubDate>Thu, 19 Nov 2026 15:16:14 +0000</pubDate></item>
        <item><title>Sans date &amp; sans lien</title></item>
        </channel></rss>
        """
        let feed = try #require(FeedParser.parse(Data(xml.utf8)))
        #expect(feed.format == "RSS")
        #expect(feed.title == "CERT-FR")
        #expect(feed.entries.count == 2)
        let first = feed.entries[0]
        #expect(first.title == "Multiples vulnérabilités dans OpenSSL (19 novembre 2026)")
        #expect(first.summary == "De multiples vulnérabilités ont été découvertes dans OpenSSL.")
        #expect(first.link?.host == "www.cert.cyber.gouv.fr")
        #expect(first.date == Date(timeIntervalSince1970: 1_795_101_374))
        #expect(feed.entries[1].title == "Sans date & sans lien")
        #expect(feed.entries[1].date == nil)
    }

    @Test func atom() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
        <title type="text">Rust Blog</title>
        <entry>
          <title>Announcing Rust 1.95.0</title>
          <link rel="replies" href="https://example.org/comments"/>
          <link rel="alternate" href="https://blog.rust-lang.org/2026/11/13/Rust-1.95.0/" type="text/html"/>
          <id>https://blog.rust-lang.org/2026/11/13/Rust-1.95.0/</id>
          <published>2026-11-13T00:00:00+00:00</published>
          <updated>2026-11-14T10:00:00.500Z</updated>
          <content type="html">&lt;p&gt;The Rust team is happy&lt;/p&gt;</content>
        </entry>
        </feed>
        """
        let feed = try #require(FeedParser.parse(Data(xml.utf8)))
        #expect(feed.format == "Atom")
        #expect(feed.title == "Rust Blog")
        let entry = try #require(feed.entries.first)
        #expect(entry.link?.absoluteString == "https://blog.rust-lang.org/2026/11/13/Rust-1.95.0/")
        #expect(entry.summary == "The Rust team is happy")
        // `published` l'emporte sur `updated`.
        #expect(entry.date == ISO8601DateFormatter().date(from: "2026-11-13T00:00:00Z"))
    }

    @Test func notAFeed() {
        #expect(FeedParser.parse(Data("<html><body>Bonjour</body></html>".utf8)) == nil)
        #expect(FeedParser.parse(Data("pas du xml".utf8)) == nil)
    }

    @Test func plainText() {
        #expect(PlainText.plain("### Summary\nAn **unauthenticated** `path` [traversal](https://x.y)", limit: 200) == "An unauthenticated path traversal")
        #expect(PlainText.plain("caf&#233; &#x2014; l&rsquo;été", limit: 100) == "café — l’été")
        let long = String(repeating: "mot ", count: 100)
        let cut = PlainText.plain(long, limit: 20)
        #expect(cut.hasSuffix("…"))
        #expect(cut.count <= 21)
    }

    @Test func dates() {
        #expect(FeedDate.parse("Tue, 20 Oct 2026 00:00:00 +0000") != nil)
        #expect(FeedDate.parse("Tue, 20 Oct 2026 00:00:00 GMT") != nil)
        #expect(FeedDate.parse("2026-11-20T00:23:45Z") != nil)
        #expect(FeedDate.parse("2026-11-20") != nil)
        #expect(FeedDate.parse("hier") == nil)
    }
}

@Suite struct AdvisoryTests {
    static let github = """
    [{"ghsa_id":"GHSA-aaaa","cve_id":"CVE-2026-1","summary":"next: authorization bypass","description":"### Summary\\nA forged header bypasses middleware.",
      "severity":"critical","published_at":"2026-11-20T00:23:45Z","html_url":"https://github.com/advisories/GHSA-aaaa",
      "vulnerabilities":[{"package":{"ecosystem":"npm","name":"next"},"vulnerable_version_range":">= 13.0.0, < 14.2.25","first_patched_version":"14.2.25"}]},
     {"ghsa_id":"GHSA-bbbb","summary":"serde: crash","description":"","severity":"medium","published_at":"2026-11-19T00:00:00Z",
      "vulnerabilities":[{"package":{"ecosystem":"rust","name":"serde"},"vulnerable_version_range":"< 1.0.100","first_patched_version":null}]}]
    """

    @Test func github() throws {
        let items = try #require(AdvisoryParser.github(Data(Self.github.utf8)))
        #expect(items.count == 2)
        let next = items[0]
        #expect(next.id == "gha|GHSA-aaaa")
        #expect(next.isCritical)
        #expect(next.cve == "CVE-2026-1")
        #expect(next.summary == "A forged header bypasses middleware.")
        #expect(next.language == "JS / TS")
        #expect(next.packages == [AdvisoryPackage(ecosystem: "npm", name: "next", range: ">= 13.0.0, < 14.2.25", fixed: "14.2.25")])
        #expect(items[1].packages.first?.ecosystem == "cargo")
        #expect(items[1].language == "Rust")
        #expect(!items[1].isSevere)
    }

    @Test func kev() throws {
        let json = """
        {"vulnerabilities":[
          {"cveID":"CVE-2026-2","vendorProject":"OpenSSL","product":"OpenSSL","vulnerabilityName":"OpenSSL Use-After-Free","dateAdded":"2026-11-18","shortDescription":"Exploited."},
          {"cveID":"CVE-2020-1","vendorProject":"Old","product":"Thing","vulnerabilityName":"Old","dateAdded":"2020-01-01","shortDescription":""}]}
        """
        let now = ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z")!
        let items = try #require(AdvisoryParser.kev(Data(json.utf8), now: now))
        #expect(items.count == 1)
        #expect(items[0].exploited)
        #expect(items[0].isCritical)
        #expect(items[0].products == ["OpenSSL", "OpenSSL"])
        #expect(items[0].link?.absoluteString == "https://nvd.nist.gov/vuln/detail/CVE-2026-2")
    }

    @Test func ranges() {
        #expect(VersionRange.contains(">= 13.0.0, < 14.2.25", "13.4.2"))
        #expect(!VersionRange.contains(">= 13.0.0, < 14.2.25", "14.2.25"))
        #expect(!VersionRange.contains(">= 13.0.0, < 14.2.25", "12.9.0"))
        #expect(VersionRange.contains("<= 4.17.20", "4.17.20"))
        #expect(VersionRange.contains("= 1.0.0", "v1.0.0"))
        #expect(!VersionRange.contains("< 2.1.0", "2.1.0"))
        #expect(VersionRange.contains("< 2.1.0", "v2.0.9"))
        #expect(VersionRange.contains(nil, "1.0"))
        // Version inconnue (pas de lockfile) : on ne conclut pas.
        #expect(!VersionRange.contains("< 2.0.0", ""))
    }
}

@Suite struct NewsMatchTests {
    private func inventory() -> NewsInventory {
        let shop = URL(fileURLWithPath: "/tmp/old-shop")
        let api = URL(fileURLWithPath: "/tmp/api")
        let manifests = [
            ProjectManifest(project: shop, ecosystem: .npm, manager: .npm, manifest: "package.json", lockfile: "package-lock.json",
                            dependencies: [Dependency(ecosystem: .npm, name: "next", version: "13.4.2", direct: true)]),
            ProjectManifest(project: api, ecosystem: .npm, manager: .pnpm, manifest: "package.json", lockfile: "pnpm-lock.yaml",
                            dependencies: [Dependency(ecosystem: .npm, name: "next", version: "15.0.0", direct: false)]),
        ]
        let packages = [
            Package(source: .homebrew, identifier: "openssl@3", version: "3.2.0"),
            Package(source: .homebrew, identifier: "make", version: "4.4"),
            Package(source: .homebrew, identifier: "google-chrome", name: "Google Chrome", version: "142.0", isCask: true),
            Package(source: .npm, identifier: "next", version: "14.0.0"),
        ]
        return NewsInventory(manifests: manifests, packages: packages)
    }

    @Test func advisoryVersions() throws {
        let item = try #require(AdvisoryParser.github(Data(AdvisoryTests.github.utf8))?.first)
        let matches = NewsMatcher.matches(item, in: inventory())
        // old-shop (13.4.2) et npm -g (14.0.0) sont touchés ; api (15.0.0) ne l'est pas.
        #expect(matches.count == 2)
        #expect(matches.allSatisfy { $0.confirmed })
        #expect(matches.contains { $0.project?.lastPathComponent == "old-shop" && $0.fixed == "14.2.25" && $0.place == "package-lock.json" })
        #expect(matches.contains { $0.project == nil && $0.place == "npm -g" })
    }

    @Test func mentions() {
        var cert = NewsItem(id: "certfr|1", sourceID: "certfr", title: "Multiples vulnérabilités dans OpenSSL", summary: "",
                            link: nil, date: .now, topic: "Cyber", category: .cyber)
        var matches = NewsMatcher.matches(cert, in: inventory())
        #expect(matches.count == 1)
        #expect(matches.first?.package == "openssl@3")
        #expect(matches.first?.confirmed == false)

        cert.title = "Vulnérabilité dans Google Chrome"
        matches = NewsMatcher.matches(cert, in: inventory())
        #expect(matches.first?.package == "Google Chrome")

        // « make » est trop courant ; « OpenSSLx » n'est pas « OpenSSL ».
        cert.title = "Comment make fonctionne avec OpenSSLx"
        #expect(NewsMatcher.matches(cert, in: inventory()).isEmpty)

        // Un billet de langage n'est jamais croisé par nom.
        var blog = cert
        blog.category = .langage
        blog.title = "OpenSSL 3.5 is out"
        #expect(NewsMatcher.matches(blog, in: inventory()).isEmpty)
    }

    @Test func topics() {
        let manifests = [
            ProjectManifest(project: URL(fileURLWithPath: "/a"), ecosystem: .npm, manager: .npm, manifest: "package.json", lockfile: nil,
                            dependencies: [Dependency(ecosystem: .npm, name: "x", version: "1")]),
            ProjectManifest(project: URL(fileURLWithPath: "/b"), ecosystem: .cargo, manager: .cargo, manifest: "Cargo.toml", lockfile: nil, dependencies: []),
        ]
        let packages = [
            Package(source: .homebrew, identifier: "postgresql@16", version: "16.4"),
            Package(source: .homebrew, identifier: "node", version: "22.0"),
            Package(source: .homebrew, identifier: "kotlin", version: "2.0", onRequest: false),
        ]
        let topics = NewsTopics.detect(manifests: manifests, packages: packages)
        #expect(topics.map(\.name) == ["JS / TS", "Rust", "PostgreSQL"])
        #expect(topics[0].reason == "1 projet")
        #expect(topics[2].reason == "Homebrew")

        let item = NewsItem(id: "x", sourceID: "hn", title: "Kubernetes 1.40 released", summary: "", link: nil, date: .now, topic: "Général", category: .general)
        #expect(NewsTopics.mentions(item, "kubernetes"))
        #expect(!NewsTopics.mentions(item, "Kube"))
    }

    @Test func defaults() {
        let rust = NewsCatalog.builtIn.first { $0.id == "rust" }!
        let hn = NewsCatalog.builtIn.first { $0.id == "hn" }!
        let gha = NewsCatalog.builtIn.first { $0.id == "gha" }!
        #expect(NewsCatalog.enabledByDefault(rust, topics: ["Rust"]))
        #expect(!NewsCatalog.enabledByDefault(rust, topics: ["Go"]))
        #expect(!NewsCatalog.enabledByDefault(hn, topics: []))
        #expect(NewsCatalog.enabledByDefault(gha, topics: []))
        #expect(Set(NewsCatalog.builtIn.map(\.id)).count == NewsCatalog.builtIn.count)
    }

    @Test func merge() {
        var state = NewsState()
        let now = Date()
        let old = NewsItem(id: "a|old", sourceID: "a", title: "Ancien", summary: "", link: nil, date: now.addingTimeInterval(-90 * 86_400), topic: "Rust", category: .langage)
        var kept = old
        kept.id = "a|kept"
        let fresh = NewsItem(id: "a|new", sourceID: "a", title: "Nouveau", summary: "", link: nil, date: now, topic: "Rust", category: .langage)
        state.starred = ["a|kept"]
        state.read = ["a|old", "a|new"]
        let added = state.merge([old, kept, fresh], now: now)
        #expect(added.count == 3)
        #expect(state.items.map(\.id) == ["a|new", "a|kept"])
        #expect(state.read == ["a|new"])
        // Relire les mêmes articles n'en ajoute pas.
        #expect(state.merge([fresh], now: now).isEmpty)
    }

    /// Lit les vraies sources : LATELIER_LIVE=1 swift test --filter liveSources
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LATELIER_LIVE"] == "1"))
    func liveSources() async {
        let outcomes = await NewsFetcher().fetch(NewsCatalog.builtIn, ecosystems: [.npm, .cargo, .pypi])
        for outcome in outcomes.sorted(by: { $0.sourceID < $1.sourceID }) {
            let newest = outcome.items.map(\.date).max().map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "-"
            print("SOURCE", outcome.sourceID, outcome.format ?? "?", outcome.items.count, newest, outcome.error ?? "ok", outcome.items.first?.title.prefix(60) ?? "")
        }
        #expect(outcomes.filter { $0.error == nil }.count >= NewsCatalog.builtIn.count - 2)
    }
}
