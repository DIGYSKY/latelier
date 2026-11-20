import Foundation

// MARK: - Modèle

public struct GitFileChange: Sendable, Hashable, Identifiable {
    /// M modifié, A ajouté, D supprimé, R renommé, U conflit, ? non suivi.
    public var code: Character
    public var path: String
    /// Ancien chemin d'un renommage.
    public var originalPath: String?
    public var staged: Bool
    public var added: Int?
    public var removed: Int?
    public var id: String { path }

    public var isUntracked: Bool { code == "?" }
    public var isConflict: Bool { code == "U" }
}

public struct GitCommitSummary: Sendable, Hashable {
    public var hash: String
    public var subject: String
    public var date: Date
}

public struct GitBranch: Sendable, Hashable, Identifiable {
    public var name: String
    public var isCurrent: Bool
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    /// Le distant a été supprimé.
    public var upstreamGone: Bool
    /// Déjà fusionnée dans la branche courante (supprimable sans perte).
    public var merged: Bool
    public var id: String { name }
}

public struct RepoStatus: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        case conflict, modified, diverged, ahead, behind, noRemote, noUpstream, clean
    }

    public var url: URL
    public var languages: [String]
    /// `nil` : HEAD détaché.
    public var branch: String?
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public var remotes: [String: String] = [:]
    public var changes: [GitFileChange] = []
    public var recentCommits: [GitCommitSummary] = []
    public var branches: [GitBranch] = []
    /// Fusion, rebase, cherry-pick en cours : on ne propose aucune action (règle n° 3).
    public var operationInProgress: String?
    public var error: String?
    public var scannedAt = Date()

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
    public var lastCommit: GitCommitSummary? { recentCommits.first }
    public var hasRemote: Bool { !remotes.isEmpty }
    public var remoteURL: String? { remotes["origin"] ?? remotes.values.sorted().first }

    public var state: State {
        if changes.contains(where: \.isConflict) || operationInProgress != nil { return .conflict }
        if !changes.isEmpty { return .modified }
        if ahead > 0 && behind > 0 { return .diverged }
        if ahead > 0 { return .ahead }
        if behind > 0 { return .behind }
        if !hasRemote { return .noRemote }
        if upstream == nil, branch != nil { return .noUpstream }
        return .clean
    }

    /// Un push simple est possible : commits en avance (ou branche à publier), sans retard ni opération en cours.
    public var canPush: Bool {
        guard hasRemote, branch != nil, operationInProgress == nil, behind == 0 else { return false }
        return ahead > 0 || (upstream == nil && !recentCommits.isEmpty)
    }

    /// Inactif : aucun commit depuis plus de 3 mois.
    public func isInactive(now: Date = .now) -> Bool {
        guard let date = lastCommit?.date else { return true }
        return now.timeIntervalSince(date) > 90 * 86_400
    }
}

// MARK: - Client

/// Appelle la CLI `git` : même comportement que dans le terminal (config, clés SSH, hooks).
public struct GitClient: Sendable {
    public let runner: CommandRunner

    public init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
    }

    /// Variables pour ne jamais rester bloqué sur une demande de mot de passe,
    /// et ne pas prendre le verrou de l'index pendant une simple lecture.
    public static let environment = [
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_SSH_COMMAND": "ssh -o BatchMode=yes",
        "LC_ALL": "C",
    ]

    public static func command(_ arguments: [String], in repo: URL) -> CommandSpec {
        CommandSpec("git", ["-c", "core.quotePath=false"] + arguments, in: repo, environment: environment)
    }

    private func lines(_ arguments: [String], in repo: URL) async -> [String]? {
        guard let result = try? await runner.run(Self.command(arguments, in: repo), timeout: .seconds(20)),
              result.succeeded else { return nil }
        return result.stdout
    }

    public func status(of repo: URL) async -> RepoStatus {
        async let porcelain = runner.run(
            Self.command(["status", "--porcelain=v2", "--branch", "--untracked-files=normal"], in: repo),
            timeout: .seconds(20)
        )
        async let numstat = lines(["diff", "--numstat", "HEAD"], in: repo)
        async let log = lines(["log", "-n", "6", "--format=%h%x1f%s%x1f%ct"], in: repo)
        async let refs = lines(["for-each-ref", "--format=%(refname:short)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(HEAD)", "refs/heads"], in: repo)
        async let merged = lines(["branch", "--merged", "HEAD", "--format=%(refname:short)"], in: repo)
        async let remotes = lines(["remote", "-v"], in: repo)

        var status = RepoStatus(url: repo, languages: Self.languages(in: repo))
        status.operationInProgress = Self.operationInProgress(in: repo)
        do {
            let result = try await porcelain
            guard result.succeeded else {
                status.error = result.stderr.first ?? "git status a échoué"
                return status
            }
            Self.parseStatus(result.stdout, into: &status)
        } catch {
            status.error = error.localizedDescription
            return status
        }
        Self.applyNumstat(await numstat ?? [], to: &status.changes)
        status.recentCommits = Self.parseLog(await log ?? [])
        status.branches = Self.parseBranches(await refs ?? [], merged: Set(await merged ?? []))
        status.remotes = Self.parseRemotes(await remotes ?? [])
        return status
    }

    // MARK: Lecture des sorties

    static func parseStatus(_ lines: [String], into status: inout RepoStatus) {
        for line in lines {
            if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                status.branch = head == "(detached)" ? nil : head
            } else if line.hasPrefix("# branch.upstream ") {
                status.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                if parts.count == 2 {
                    status.ahead = Int(parts[0].dropFirst()) ?? 0
                    status.behind = Int(parts[1].dropFirst()) ?? 0
                }
            } else if line.hasPrefix("? ") {
                status.changes.append(GitFileChange(code: "?", path: String(line.dropFirst(2)), staged: false))
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("u ") {
                let kind = line.first!
                let fieldCount = kind == "1" ? 9 : kind == "2" ? 10 : 11
                let fields = line.split(separator: " ", maxSplits: fieldCount - 1, omittingEmptySubsequences: false)
                guard fields.count == fieldCount else { continue }
                let xy = Array(fields[1])
                var path = String(fields[fieldCount - 1])
                var original: String?
                if kind == "2", let tab = path.firstIndex(of: "\t") {
                    original = String(path[path.index(after: tab)...])
                    path = String(path[..<tab])
                }
                let x = xy[0], y = xy[1]
                let code: Character = kind == "u" ? "U" : (x != "." ? x : y)
                status.changes.append(GitFileChange(code: code, path: path, originalPath: original, staged: x != "." && kind != "u"))
            }
        }
    }

    static func applyNumstat(_ lines: [String], to changes: inout [GitFileChange]) {
        var counts: [String: (Int?, Int?)] = [:]
        for line in lines {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { continue }
            var path = String(parts[2])
            // Renommage : « ancien => nouveau » ou « dossier/{a => b}/f ».
            if path.contains(" => ") {
                if let open = path.firstIndex(of: "{"), let close = path.firstIndex(of: "}") {
                    let inner = path[path.index(after: open)..<close].components(separatedBy: " => ")
                    path = String(path[..<open]) + (inner.last ?? "") + String(path[path.index(after: close)...])
                    path = path.replacingOccurrences(of: "//", with: "/")
                } else {
                    path = path.components(separatedBy: " => ").last ?? path
                }
            }
            counts[path] = (Int(parts[0]), Int(parts[1]))   // « - » pour un fichier binaire
        }
        for index in changes.indices {
            if let (added, removed) = counts[changes[index].path] {
                changes[index].added = added
                changes[index].removed = removed
            }
        }
    }

    static func parseLog(_ lines: [String]) -> [GitCommitSummary] {
        lines.compactMap { line in
            let parts = line.components(separatedBy: "\u{1F}")
            guard parts.count == 3, let seconds = TimeInterval(parts[2]) else { return nil }
            return GitCommitSummary(hash: parts[0], subject: parts[1], date: Date(timeIntervalSince1970: seconds))
        }
    }

    static func parseBranches(_ lines: [String], merged: Set<String>) -> [GitBranch] {
        lines.compactMap { line in
            let parts = line.components(separatedBy: "\u{1F}")
            guard parts.count == 4 else { return nil }
            let track = parts[2]
            func count(_ word: String) -> Int {
                guard let range = track.range(of: word + " ") else { return 0 }
                return Int(track[range.upperBound...].prefix { $0.isNumber }) ?? 0
            }
            let current = parts[3] == "*"
            return GitBranch(
                name: parts[0], isCurrent: current, upstream: parts[1].isEmpty ? nil : parts[1],
                ahead: count("ahead"), behind: count("behind"), upstreamGone: track == "gone",
                merged: !current && merged.contains(parts[0])
            )
        }
        .sorted { ($0.isCurrent ? 0 : 1, $0.name) < ($1.isCurrent ? 0 : 1, $1.name) }
    }

    static func parseRemotes(_ lines: [String]) -> [String: String] {
        var remotes: [String: String] = [:]
        for line in lines where line.hasSuffix("(fetch)") {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            if parts.count >= 2 { remotes[String(parts[0])] = String(parts[1]) }
        }
        return remotes
    }

    static func operationInProgress(in repo: URL) -> String? {
        let git = repo.appendingPathComponent(".git")
        let fm = FileManager.default
        let checks: [(String, String)] = [
            ("MERGE_HEAD", "fusion en cours"), ("rebase-merge", "rebase en cours"), ("rebase-apply", "rebase en cours"),
            ("CHERRY_PICK_HEAD", "cherry-pick en cours"), ("REVERT_HEAD", "revert en cours"), ("BISECT_LOG", "bisect en cours"),
        ]
        return checks.first { fm.fileExists(atPath: git.appendingPathComponent($0.0).path) }?.1
    }

    /// Langages devinés d'après les fichiers du premier niveau.
    static func languages(in repo: URL) -> [String] {
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: repo.path)) ?? [])
        func has(_ file: String) -> Bool { names.contains(file) }
        var result: [String] = []
        if has("tsconfig.json") { result.append("TypeScript") } else if has("package.json") { result.append("JavaScript") }
        if has("Cargo.toml") { result.append("Rust") }
        if has("build.gradle.kts") || has("settings.gradle.kts") { result.append("Kotlin") }
        if has("pom.xml") || has("build.gradle") { result.append("Java") }
        if has("pyproject.toml") || has("requirements.txt") || has("setup.py") { result.append("Python") }
        if has("go.mod") { result.append("Go") }
        if has("Package.swift") || names.contains(where: { $0.hasSuffix(".xcodeproj") }) { result.append("Swift") }
        if has("Gemfile") { result.append("Ruby") }
        if has("composer.json") { result.append("PHP") }
        if has("build.sbt") { result.append("Scala") }
        if has("pubspec.yaml") { result.append("Dart") }
        if names.contains(where: { $0.hasSuffix(".csproj") || $0.hasSuffix(".sln") }) { result.append("C#") }
        if has("CMakeLists.txt") || has("Makefile") && result.isEmpty { result.append("C/C++") }
        return result
    }

    // MARK: Actions (toujours montrées en aperçu, sauf fetch)

    public static func fetchPlan(_ repos: [RepoStatus]) -> ActionPlan {
        ActionPlan(
            title: repos.count == 1 ? "Fetch : \(repos[0].name)" : "Fetch de \(repos.count) dépôts",
            summary: "Récupère les nouveautés des distants. Ne touche ni au code ni aux branches locales.",
            kind: .git, risk: .safe, reversible: true,
            steps: repos.map { .command(command(["fetch", "--prune"], in: $0.url)) },
            stopOnFailure: false
        )
    }

    public static func pullPlan(_ repo: RepoStatus) -> ActionPlan {
        ActionPlan(
            title: "Pull : \(repo.name)",
            summary: "Récupère \(repo.behind) commit(s) de \(repo.upstream ?? "la branche distante") en avance rapide seulement : si les historiques ont divergé, rien n’est modifié.",
            kind: .git, risk: repo.changes.isEmpty ? .safe : .caution, reversible: false,
            steps: [.command(command(["pull", "--ff-only"], in: repo.url))]
        )
    }

    public static func pushPlan(_ repo: RepoStatus) -> ActionPlan? {
        guard let branch = repo.branch, repo.hasRemote else { return nil }
        let remote = repo.remotes["origin"] != nil ? "origin" : repo.remotes.keys.sorted()[0]
        let arguments = repo.upstream == nil ? ["push", "--set-upstream", remote, branch] : ["push"]
        return ActionPlan(
            title: "Push : \(repo.name)",
            summary: repo.upstream == nil
                ? "Publie la branche \(branch) sur \(remote) pour la première fois."
                : "Envoie \(repo.ahead) commit(s) de \(branch) vers \(repo.upstream!). Jamais de push forcé.",
            kind: .git, risk: .safe, reversible: false,
            steps: [.command(command(arguments, in: repo.url))]
        )
    }

    /// Commit des seuls fichiers choisis (les autres restent tels quels).
    public static func commitPlan(_ repo: RepoStatus, files: [GitFileChange], message: String) -> ActionPlan? {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !files.isEmpty, !message.isEmpty, !files.contains(where: \.isConflict) else { return nil }
        var steps: [ActionStep] = []
        let untracked = files.filter(\.isUntracked).map(\.path)
        if !untracked.isEmpty { steps.append(.command(command(["add", "--"] + untracked, in: repo.url))) }
        let paths = files.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        steps.append(.command(command(["commit", "-m", message, "--"] + paths, in: repo.url)))
        return ActionPlan(
            title: "Commit : \(repo.name)",
            summary: "\(files.count) fichier(s) sur \(repo.branch ?? "HEAD détaché") : « \(message) »",
            kind: .git, risk: .safe, reversible: true, steps: steps
        )
    }
}

// MARK: - Détection des dépôts

public struct RepoScanner: Sendable {
    public var roots: [URL]
    public var maxDepth = 6

    public init(roots: [URL], maxDepth: Int = 6) {
        self.roots = roots
        self.maxDepth = maxDepth
    }

    private static let skipped: Set<String> = ["node_modules", "Library", "Applications", "target", "build", "dist", "vendor", "Pods"]

    /// Dossiers contenant `.git` (sans descendre dans un dépôt déjà trouvé).
    public func repositories() -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        for root in roots {
            var stack: [(URL, Int)] = [(root, 0)]
            while let (dir, depth) = stack.popLast() {
                if Task.isCancelled { return found }
                if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                    found.append(dir.standardizedFileURL)
                    continue
                }
                guard depth < maxDepth,
                      let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
                else { continue }
                for child in children where !Self.skipped.contains(child.lastPathComponent) {
                    guard let values = try? child.resourceValues(forKeys: keys),
                          values.isDirectory == true, values.isSymbolicLink != true else { continue }
                    stack.append((child, depth + 1))
                }
            }
        }
        return found.uniqued().sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Détecte et lit l'état de tous les dépôts (8 à la fois).
    public func scan(git: GitClient) async -> [RepoStatus] {
        let repos = repositories()
        return await withTaskGroup(of: RepoStatus.self) { group in
            var iterator = repos.makeIterator()
            for _ in 0..<8 {
                guard let repo = iterator.next() else { break }
                group.addTask { await git.status(of: repo) }
            }
            var results: [RepoStatus] = []
            while let status = await group.next() {
                results.append(status)
                if let next = iterator.next() { group.addTask { await git.status(of: next) } }
            }
            return results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}
