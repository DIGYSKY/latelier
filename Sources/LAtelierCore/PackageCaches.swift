import Foundation

/// Stockage › Caches : caches des gestionnaires de paquets, Xcode, `~/.cache`, toolchains (protégées).
/// La commande officielle de l'outil est préférée quand elle existe.
public struct PackageCacheScanner: Sendable {
    public var home: URL
    public var runner: CommandRunner

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), runner: CommandRunner = CommandRunner()) {
        self.home = home
        self.runner = runner
    }

    private func path(_ relative: String) -> URL { home.appending(path: relative) }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    public func scan() async -> [CleanupGroup] {
        // Emplacements donnés par les outils eux-mêmes, quand ils sont installés.
        async let pnpmStore = toolPath("pnpm", ["store", "path"])
        async let goModCache = toolPath("go", ["env", "GOMODCACHE"])
        let pnpm = await pnpmStore.map(URL.init(fileURLWithPath:)) ?? path("Library/pnpm/store")
        let gomod = await goModCache.map(URL.init(fileURLWithPath:)) ?? path("go/pkg/mod")

        let candidates = managerCandidates(pnpm: pnpm, gomod: gomod) + xcodeCandidates() + dotCacheCandidates()
        let toolchains = toolchainCandidates()
        let sizes = await DiskUsage.measure((candidates + toolchains).map(\.url))

        func items(_ list: [Candidate]) -> [CleanupItem] {
            list.compactMap { candidate in
                let size = sizes[candidate.url]?.bytes ?? 0
                guard size > 1_000_000 else { return nil }
                return candidate.item(bytes: size, home: home.path)
            }
            .sorted { ($0.isLocked ? 1 : 0, -$0.bytes) < ($1.isLocked ? 1 : 0, -$1.bytes) }
        }

        let groups: [(String, String, String, CleanupGroup.Tone, [Candidate])] = [
            ("managers", "Gestionnaires de paquets", "Re-téléchargés à la demande au prochain install", .normal,
             candidates.filter { $0.group == "managers" }),
            ("xcode", "Xcode", "~/Library/Developer", .normal, candidates.filter { $0.group == "xcode" }),
            ("dotcache", "~/.cache · au cas par cas", "Chaque dossier est décrit ; rien n’est coché sans explication", .neutral,
             candidates.filter { $0.group == "dotcache" }),
            ("toolchains", "Toolchains · protégées", "Les supprimer casserait vos outils", .neutral, toolchains),
        ]
        return groups.compactMap { id, title, detail, tone, list in
            let rows = items(list)
            return rows.isEmpty ? nil : CleanupGroup(id: id, title: title, detail: detail, tone: tone, items: rows)
        }
    }

    // MARK: Candidats

    struct Candidate: Sendable {
        var group: String
        var name: String
        var url: URL
        var detail: String?
        var meta: String?
        var risk: Risk = .safe
        var selected = true
        var commands: [CommandSpec] = []
        var lockReason: String?
        var tag: String?

        /// « npm cache clean --force », sans le chemin de l'outil.
        static func short(_ spec: CommandSpec) -> String {
            ([URL(fileURLWithPath: spec.tool).lastPathComponent] + spec.arguments).joined(separator: " ")
        }

        func item(bytes: Int64, home: String) -> CleanupItem {
            let shownPath = url.abbreviatingHome(home)
            return CleanupItem(
                id: "cache:" + url.path, name: name,
                detail: detail ?? (commands.isEmpty ? shownPath : commands.map(Self.short).joined(separator: " && ")),
                detailIsPath: detail == nil,
                meta: meta ?? (commands.isEmpty ? nil : shownPath),
                tag: tag, risk: risk, lockReason: lockReason, selectedByDefault: selected && lockReason == nil,
                entries: [CleanupItem.Entry(url: url, bytes: bytes)],
                action: commands.isEmpty ? .remove : .commands(commands)
            )
        }
    }

    private func command(_ tool: String, _ arguments: [String]) -> [CommandSpec] {
        guard let url = runner.locator.locate(tool) else { return [] }
        return [CommandSpec(url.path, arguments)]
    }

    func managerCandidates(pnpm: URL, gomod: URL) -> [Candidate] {
        var list: [Candidate] = []
        let npm = command("npm", ["cache", "clean", "--force"])
        list.append(Candidate(group: "managers", name: "npm", url: path(".npm/_cacache"), commands: npm,
                              lockReason: npm.isEmpty ? "npm introuvable : à nettoyer avec npm" : nil))
        let pnpmPrune = command("pnpm", ["store", "prune"])
        list.append(Candidate(group: "managers", name: "pnpm", url: pnpm, meta: "paquets non référencés seulement",
                              commands: pnpmPrune, lockReason: pnpmPrune.isEmpty ? "pnpm introuvable : à nettoyer avec pnpm" : nil))
        let bun = command("bun", ["pm", "cache", "rm"])
        list.append(Candidate(group: "managers", name: "Bun", url: path(".bun/install/cache"), commands: bun))
        let go = command("go", ["clean", "-modcache"])
        list.append(Candidate(group: "managers", name: "Go (modules)", url: gomod, commands: go,
                              lockReason: go.isEmpty ? "go introuvable : les fichiers sont en lecture seule" : nil))
        list.append(Candidate(group: "managers", name: "Cargo (registre)", url: path(".cargo/registry/cache"),
                              meta: "archives des crates téléchargées"))
        list.append(Candidate(group: "managers", name: "Cargo (sources)", url: path(".cargo/registry/src"),
                              meta: "sources décompressées, recréées au build"))
        list.append(Candidate(group: "managers", name: "Maven", url: path(".m2/repository"),
                              meta: "Build suivant plus long", risk: .caution, selected: false))
        list.append(Candidate(group: "managers", name: "Gradle", url: path(".gradle/caches"),
                              meta: "Build suivant plus long", risk: .caution, selected: false))
        list.append(Candidate(group: "managers", name: "Composer", url: path(".composer/cache"), meta: "cache PHP"))
        // Les caches rangés dans ~/Library/Caches (yarn, pip, Homebrew, CocoaPods, Deno) sont dans Stockage › Système.
        return list.filter { Self.exists($0.url) }
    }

    func xcodeCandidates() -> [Candidate] {
        let derived = path("Library/Developer/Xcode/DerivedData")
        let projects = ((try? FileManager.default.contentsOfDirectory(atPath: derived.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "ModuleCache.noindex" }.count
        var list = [
            Candidate(group: "xcode", name: "DerivedData", url: derived, meta: projects > 0 ? "\(projects) projet\(projects > 1 ? "s" : "")" : nil),
            Candidate(group: "xcode", name: "Supports d’appareils iOS", url: path("Library/Developer/Xcode/iOS DeviceSupport"),
                      meta: "recréés à la connexion d’un appareil"),
            Candidate(group: "xcode", name: "Caches des simulateurs", url: path("Library/Developer/CoreSimulator/Caches")),
            Candidate(group: "xcode", name: "Archives", url: path("Library/Developer/Xcode/Archives"),
                      meta: "vos builds archivés (dSYM pour les rapports de plantage)", risk: .caution, selected: false),
        ]
        if let xcrun = runner.locator.locate("xcrun"),
           FileManager.default.fileExists(atPath: "/Applications/Xcode.app") {
            list.append(Candidate(group: "xcode", name: "Simulateurs indisponibles", url: path("Library/Developer/CoreSimulator/Devices"),
                                  meta: "seuls ceux d’un runtime absent sont supprimés", risk: .caution, selected: false,
                                  commands: [CommandSpec(xcrun.path, ["simctl", "delete", "unavailable"])]))
        }
        return list.filter { Self.exists($0.url) }
    }

    /// Dossiers connus de `~/.cache` : (nom, description, risque, commande).
    static let knownDotCache: [String: (String, String, Risk)] = [
        "pip": ("pip", "Paquets Python téléchargés", .safe),
        "uv": ("uv", "Paquets Python téléchargés par uv", .safe),
        "pypoetry": ("Poetry", "Paquets Python téléchargés", .safe),
        "pre-commit": ("pre-commit", "Environnements des hooks, recréés au besoin", .safe),
        "node": ("Corepack", "Versions de pnpm / yarn téléchargées par Corepack", .safe),
        "node-gyp": ("node-gyp", "En-têtes Node pour compiler les modules natifs", .safe),
        "typescript": ("TypeScript", "Types téléchargés par l’éditeur", .safe),
        "yarn": ("Yarn", "Paquets téléchargés", .safe),
        "deno": ("Deno", "Modules téléchargés", .safe),
        "prisma": ("Prisma", "Moteurs Prisma, re-téléchargés au prochain generate", .safe),
        "giget": ("giget", "Modèles de projets téléchargés", .safe),
        "puppeteer": ("Puppeteer", "Navigateurs téléchargés pour les tests (long à re-télécharger)", .caution),
        "selenium": ("Selenium", "Pilotes de navigateurs", .safe),
        "huggingface": ("Hugging Face", "Modèles téléchargés : longs à re-télécharger", .caution),
        "torch": ("PyTorch", "Modèles téléchargés", .caution),
        "whisper": ("Whisper", "Modèles de transcription", .caution),
        "gitstatus": ("gitstatus", "Binaire du prompt Powerlevel10k : re-téléchargé au prochain shell", .caution),
        "gh": ("GitHub CLI", "Extensions et données de gh", .caution),
        "codex-runtimes": ("Codex", "Environnements d’exécution de Codex (OpenAI), re-téléchargés au besoin", .caution),
        "claude": ("Claude Code", "Cache de Claude Code", .caution),
        "opencode": ("opencode", "Cache d’opencode", .caution),
        "outlines": ("Outlines", "Grammaires compilées (bibliothèque Python outlines)", .safe),
    ]

    func dotCacheCandidates() -> [Candidate] {
        let root = path(".cache")
        let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return children.compactMap { url -> Candidate? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let name = url.lastPathComponent
            // Fichiers du shell (Powerlevel10k) : tout petits, on n'y touche pas.
            if name.hasPrefix("p10k") { return nil }
            if let known = Self.knownDotCache[name] {
                return Candidate(group: "dotcache", name: known.0, url: url, detail: "~/.cache/\(name) · \(known.1)",
                                 meta: known.2 == .safe ? "recréable" : "à vérifier", risk: known.2, selected: known.2 == .safe)
            }
            return Candidate(group: "dotcache", name: name, url: url, detail: "~/.cache/\(name) · outil non identifié",
                             meta: "à vérifier", risk: .caution, selected: false)
        }
    }

    func toolchainCandidates() -> [Candidate] {
        [
            (".rustup", "Toolchains Rust installées"), (".cargo/bin", "Binaires installés via cargo install"),
            (".nvm/versions", "Versions de Node.js"), (".pyenv/versions", "Versions de Python"),
            (".volta", "Versions de Node.js (Volta)"), (".local/share/mise/installs", "Versions installées par mise"),
            (".sdkman/candidates", "JDK et outils Java"), (".bun/bin", "Bun"), (".deno/bin", "Deno"),
            ("go/bin", "Binaires installés via go install"),
        ]
        .map { relative, detail in
            Candidate(group: "toolchains", name: "~/" + relative, url: path(relative), detail: detail, meta: "—",
                      risk: .protected, selected: false, lockReason: "toolchain : jamais supprimée")
        }
        .filter { Self.exists($0.url) }
    }

    private func toolPath(_ tool: String, _ arguments: [String]) async -> String? {
        guard let url = runner.locator.locate(tool),
              let result = try? await runner.run(CommandSpec(url.path, arguments), timeout: .seconds(10)),
              result.succeeded else { return nil }
        let text = result.stdout.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("/") ? text : nil
    }
}
