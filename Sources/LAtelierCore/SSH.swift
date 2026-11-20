import Foundation

// MARK: - ~/.ssh/config

/// Une option d'un bloc `Host` (`ForwardAgent yes`).
public struct SSHOption: Sendable, Hashable {
    public var key: String
    public var value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

/// Une connexion enregistrée dans `~/.ssh/config` (un bloc `Host` sans joker).
public struct SSHHost: Sendable, Hashable, Identifiable {
    /// Nom court utilisé avec `ssh <alias>`. Les autres noms du même bloc sont dans `otherAliases`.
    public var alias: String
    public var otherAliases: [String]
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var proxyJump: String?
    /// Toutes les autres options, dans leur ordre d'origine.
    public var extra: [SSHOption]
    /// Commentaire (lignes `#`) juste au-dessus du bloc.
    public var note: String?
    /// Fichier d'où vient le bloc. Seul `~/.ssh/config` est modifiable.
    public var source: URL
    public var editable: Bool

    public var id: String { alias }

    public init(
        alias: String, otherAliases: [String] = [], hostName: String? = nil, user: String? = nil, port: Int? = nil,
        identityFile: String? = nil, proxyJump: String? = nil, extra: [SSHOption] = [], note: String? = nil,
        source: URL = SSHConfig.defaultURL, editable: Bool = true
    ) {
        self.alias = alias
        self.otherAliases = otherAliases
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
        self.extra = extra
        self.note = note
        self.source = source
        self.editable = editable
    }

    /// `deploy@exemple.fr:2222`, pour l'affichage.
    public var destination: String {
        var text = hostName ?? alias
        if let user { text = "\(user)@\(text)" }
        if let port, port != 22 { text += ":\(port)" }
        return text
    }

    /// Lignes du bloc tel qu'il sera écrit.
    public func render(indent: String = "    ") -> [String] {
        var lines: [String] = []
        if let note, !note.isEmpty {
            lines += note.split(separator: "\n", omittingEmptySubsequences: false).map { "# " + $0 }
        }
        lines.append("Host " + ([alias] + otherAliases).joined(separator: " "))
        func add(_ key: String, _ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return }
            lines.append("\(indent)\(key) \(SSHConfig.quoteValue(value))")
        }
        add("HostName", hostName)
        add("User", user)
        add("Port", port.map(String.init))
        add("IdentityFile", identityFile)
        add("ProxyJump", proxyJump)
        for option in extra { add(option.key, option.value) }
        return lines
    }

    /// Erreurs de saisie, en clair (vide si tout va bien).
    public func problems(existing: [SSHHost], replacing original: String? = nil) -> [String] {
        var list: [String] = []
        if alias.isEmpty { list.append(String(localized: "Donnez un nom à la connexion.")) }
        if alias.contains(where: { $0.isWhitespace || "*?!,#\"'".contains($0) }) {
            list.append(String(localized: "Le nom ne peut contenir ni espace, ni guillemet, ni * ? ! , #."))
        }
        if existing.contains(where: { $0.alias.caseInsensitiveCompare(alias) == .orderedSame && $0.alias != original }) {
            list.append(String(localized: "Une connexion « \(alias) » existe déjà."))
        }
        if (hostName ?? "").isEmpty { list.append(String(localized: "Indiquez l’adresse du serveur (nom de domaine ou IP).")) }
        if let port, !(1...65_535).contains(port) { list.append("Le port doit être compris entre 1 et 65535.") }
        let fields = [alias, hostName, user, identityFile, proxyJump, note].compactMap { $0 } + extra.flatMap { [$0.key, $0.value] }
        if fields.contains(where: { $0.contains("\r") }) || [alias, hostName, user, identityFile, proxyJump].compactMap({ $0 }).contains(where: { $0.contains("\n") }) {
            list.append(String(localized: "Un champ contient un retour à la ligne."))
        }
        for option in extra where option.key.contains(where: { !$0.isLetter && !$0.isNumber }) || option.key.isEmpty {
            list.append(String(localized: "Option invalide : « \(option.key) »."))
        }
        for option in extra where ["host", "match", "include"].contains(option.key.lowercased()) {
            list.append(String(localized: "« \(option.key) » ne peut pas être utilisée dans un bloc."))
        }
        return list
    }
}

/// Lecture et réécriture de `~/.ssh/config`, en gardant tout ce qu'on ne touche pas
/// (commentaires, blocs `Match`, `Host *`, options inconnues).
public struct SSHConfig: Sendable {
    public static var defaultURL: URL {
        // Captures d'écran (README) : LATELIER_SSH_CONFIG=/chemin/vers/une/config/de/démo
        if let demo = ProcessInfo.processInfo.environment["LATELIER_SSH_CONFIG"] { return URL(fileURLWithPath: demo) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config")
    }

    struct Block: Sendable {
        /// Lignes `[start, end)` du fichier, commentaire de tête compris.
        var start: Int
        var end: Int
        var host: SSHHost?
        var patterns: [String]
    }

    public let url: URL
    public let text: String
    let lines: [String]
    let blocks: [Block]
    /// Fichiers inclus (`Include`), lus en lecture seule.
    public let includes: [URL]
    /// Blocs génériques (`Host *`, `Host *.interne`) : options par défaut, non listés comme connexions.
    public let wildcardPatterns: [String]

    public init(url: URL = SSHConfig.defaultURL, text: String, editable: Bool = true) {
        self.url = url
        self.text = text
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        self.lines = lines
        var blocks: [Block] = []
        var includes: [URL] = []
        var wildcards: [String] = []
        var current: Block?

        func close(at index: Int) {
            guard var block = current else { return }
            // Les commentaires et lignes vides en fin de bloc appartiennent au bloc suivant.
            var end = index
            while end > block.start + 1, Self.isTrivia(lines[end - 1]) { end -= 1 }
            block.end = end
            blocks.append(block)
            current = nil
        }

        for (index, line) in lines.enumerated() {
            guard let (key, value) = Self.split(line) else { continue }
            switch key.lowercased() {
            case "host", "match":
                close(at: index)
                // Commentaire juste au-dessus (sans ligne vide entre les deux).
                var start = index
                while start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).hasPrefix("#"),
                      start - 1 >= (blocks.last?.end ?? 0) {
                    start -= 1
                }
                let patterns = key.lowercased() == "host" ? Self.words(value) : []
                current = Block(start: start, end: lines.count, host: nil, patterns: patterns)
                if key.lowercased() == "host" {
                    let plain = patterns.filter { !$0.contains(where: { "*?!".contains($0) }) }
                    if patterns.count == plain.count, let first = plain.first {
                        let note = lines[start..<index].map { line -> String in
                            var text = line.trimmingCharacters(in: .whitespaces)
                            text.removeFirst()
                            return text.hasPrefix(" ") ? String(text.dropFirst()) : text
                        }.joined(separator: "\n")
                        current?.host = SSHHost(alias: first, otherAliases: Array(plain.dropFirst()), note: note.isEmpty ? nil : note,
                                                source: url, editable: editable)
                    } else {
                        wildcards.append(patterns.joined(separator: " "))
                    }
                }
            case "include":
                for pattern in Self.words(value) {
                    includes += Self.expandInclude(pattern, base: url.deletingLastPathComponent())
                }
            default:
                guard current?.host != nil else { continue }
                switch key.lowercased() {
                case "hostname": current?.host?.hostName = value
                case "user": current?.host?.user = value
                case "port": current?.host?.port = Int(value)
                case "identityfile" where current?.host?.identityFile == nil: current?.host?.identityFile = value
                case "proxyjump": current?.host?.proxyJump = value
                default: current?.host?.extra.append(SSHOption(key, value))
                }
            }
        }
        close(at: lines.count)
        self.blocks = blocks
        self.includes = includes
        self.wildcardPatterns = wildcards
    }

    /// Lit le fichier (vide s'il n'existe pas encore).
    public static func load(_ url: URL = SSHConfig.defaultURL) -> SSHConfig {
        SSHConfig(url: url, text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    /// Connexions de ce fichier.
    public var hosts: [SSHHost] { blocks.compactMap(\.host) }

    /// Connexions de ce fichier et des fichiers inclus (en lecture seule), sans doublon.
    public func allHosts() -> [SSHHost] {
        var list = hosts
        var seen = Set(list.map(\.alias))
        for include in includes where include.standardizedFileURL != url.standardizedFileURL {
            guard let text = try? String(contentsOf: include, encoding: .utf8) else { continue }
            for host in SSHConfig(url: include, text: text, editable: false).hosts where seen.insert(host.alias).inserted {
                list.append(host)
            }
        }
        return list
    }

    /// Texte du bloc d'une connexion, tel qu'il est dans le fichier.
    public func blockText(_ alias: String) -> String? {
        guard let block = blocks.first(where: { $0.host?.alias == alias }) else { return nil }
        return lines[block.start..<block.end].joined(separator: "\n")
    }

    // MARK: Modifications (rendent le nouveau texte du fichier)

    public func adding(_ host: SSHHost) -> String {
        var result = lines
        while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty { result.removeLast() }
        if !result.isEmpty { result.append("") }
        result += host.render(indent: indentation)
        return result.joined(separator: "\n") + "\n"
    }

    public func replacing(_ alias: String, with host: SSHHost) -> String? {
        guard let block = blocks.first(where: { $0.host?.alias == alias }) else { return nil }
        // Les commentaires à l'intérieur du bloc sont gardés, juste sous la ligne Host.
        let hostLine = (block.start..<block.end).first { Self.split(lines[$0])?.0.lowercased() == "host" } ?? block.start
        let innerComments = lines[(hostLine + 1)..<block.end].filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        var rendered = host.render(indent: indentation(of: block))
        if let index = rendered.firstIndex(where: { $0.hasPrefix("Host ") }) {
            rendered.insert(contentsOf: innerComments, at: index + 1)
        }
        var result = lines
        result.replaceSubrange(block.start..<block.end, with: rendered)
        return result.joined(separator: "\n") + "\n"
    }

    public func removing(_ alias: String) -> String? {
        guard let block = blocks.first(where: { $0.host?.alias == alias }) else { return nil }
        var result = lines
        var end = block.end
        // Retire aussi la ligne vide qui suivait, pour ne pas en laisser deux.
        if end < result.count, result[end].trimmingCharacters(in: .whitespaces).isEmpty,
           block.start == 0 || result[block.start - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            end += 1
        }
        result.removeSubrange(block.start..<end)
        while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty { result.removeLast() }
        return result.isEmpty ? "" : result.joined(separator: "\n") + "\n"
    }

    /// Lignes retirées et ajoutées entre deux versions (pour l'aperçu).
    public static func diff(_ before: String, _ after: String) -> (removed: [String], added: [String]) {
        let old = before.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let new = after.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var remaining = new
        var removed: [String] = []
        for line in old {
            if let index = remaining.firstIndex(of: line) { remaining.remove(at: index) } else { removed.append(line) }
        }
        var leftovers = old
        var added: [String] = []
        for line in new {
            if let index = leftovers.firstIndex(of: line) { leftovers.remove(at: index) } else { added.append(line) }
        }
        return (removed, added)
    }

    // MARK: Outils

    private var indentation: String {
        blocks.lazy.compactMap { self.indentation(of: $0) }.first ?? "    "
    }

    private func indentation(of block: Block) -> String {
        for line in lines[block.start..<block.end] {
            guard let (key, _) = Self.split(line), !["host", "match"].contains(key.lowercased()) else { continue }
            let prefix = line.prefix { $0 == " " || $0 == "\t" }
            if !prefix.isEmpty { return String(prefix) }
        }
        return "    "
    }

    static func isTrivia(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    /// `Clé valeur` ou `Clé=valeur` ; rien pour un commentaire ou une ligne vide.
    static func split(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let separator = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { return (trimmed, "") }
        let key = String(trimmed[..<separator])
        var value = trimmed[separator...].drop { $0 == " " || $0 == "\t" }
        if value.hasPrefix("=") { value = value.dropFirst().drop { $0 == " " || $0 == "\t" } }
        var text = String(value).trimmingCharacters(in: .whitespaces)
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\""), !text.dropFirst().dropLast().contains("\"") {
            text = String(text.dropFirst().dropLast())
        }
        return (key, text)
    }

    /// Découpe une valeur en mots, en respectant les guillemets.
    static func words(_ value: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted = false
        for character in value {
            if character == "\"" { quoted.toggle(); continue }
            if character.isWhitespace && !quoted {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    static func quoteValue(_ value: String) -> String {
        value.contains(where: \.isWhitespace) && !value.hasPrefix("\"") ? "\"\(value)\"" : value
    }

    static func expandInclude(_ pattern: String, base: URL) -> [URL] {
        var path = (pattern as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = base.appendingPathComponent(path).path }
        guard path.contains(where: { "*?[".contains($0) }) else { return [URL(fileURLWithPath: path)] }
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(path, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { index in
            result.gl_pathv[index].map { URL(fileURLWithPath: String(cString: $0)) }
        }
    }
}

/// Clés privées de `~/.ssh` (celles qui ont une `.pub` à côté).
public enum SSHKeys {
    public static func list(in folder: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".pub") }
            .map { String($0.dropLast(4)) }
            .filter { names.contains($0) }
            .sorted()
            .map { "~/.ssh/\($0)" }
    }
}

// MARK: - Fichiers distants

public struct RemoteFile: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case directory, file, link, other }

    public var name: String
    public var path: String
    public var kind: Kind
    public var size: Int64
    public var modified: Date?
    public var permissions: String
    public var owner: String
    public var linkTarget: String?

    public var id: String { path }
    public var isDirectory: Bool { kind == .directory }
    public var isHidden: Bool { name.hasPrefix(".") }
    public var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    public init(name: String, path: String, kind: Kind, size: Int64, modified: Date?, permissions: String, owner: String, linkTarget: String? = nil) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.owner = owner
        self.linkTarget = linkTarget
    }
}

public enum RemotePath {
    public static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    public static func parent(_ path: String) -> String {
        guard path != "/" else { return "/" }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    /// `/home/deploy/app` → [("/", "/"), ("home", "/home"), …].
    public static func crumbs(_ path: String) -> [(name: String, path: String)] {
        var list: [(String, String)] = [("/", "/")]
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            list.append((String(part), current))
        }
        return list
    }

    /// Nom de fichier acceptable sur le serveur (pas de / ni de nom vide).
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") && !name.contains("\n")
    }
}

/// Analyse la sortie de `ls -la` (GNU, BSD, BusyBox ; avec ou sans `--time-style=+%s`).
public enum RemoteListing {
    public static func parse(_ lines: [String], directory: String, now: Date = .now) -> [RemoteFile] {
        lines.compactMap { parseLine($0, directory: directory, now: now) }
            .filter { $0.name != "." && $0.name != ".." }
    }

    static func parseLine(_ line: String, directory: String, now: Date) -> RemoteFile? {
        guard let type = line.first, "-dlcbps".contains(type), line.count > 10 else { return nil }
        var fields: [Substring] = []
        var index = line.startIndex
        func nextField() -> Substring? {
            while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
            guard index < line.endIndex else { return nil }
            let start = index
            while index < line.endIndex, line[index] != " " { index = line.index(after: index) }
            return line[start..<index]
        }
        // droits, liens, propriétaire, groupe, taille
        for _ in 0..<5 { guard let field = nextField() else { return nil }; fields.append(field) }
        // Périphérique : « 8, 1 » à la place de la taille.
        if fields[4].hasSuffix(",") { _ = nextField() }
        var modified: Date?
        guard let first = nextField() else { return nil }
        if first.count >= 9, first.allSatisfy(\.isNumber), let seconds = TimeInterval(first) {
            modified = Date(timeIntervalSince1970: seconds)
        } else {
            guard let day = nextField(), let timeOrYear = nextField() else { return nil }
            modified = date(month: String(first), day: String(day), timeOrYear: String(timeOrYear), now: now)
        }
        // Le nom : tout le reste, après un seul espace.
        guard index < line.endIndex else { return nil }
        var name = String(line[line.index(after: index)...])
        var target: String?
        let kind: RemoteFile.Kind
        switch type {
        case "d": kind = .directory
        case "-": kind = .file
        case "l":
            kind = .link
            if let arrow = name.range(of: " -> ") {
                target = String(name[arrow.upperBound...])
                name = String(name[..<arrow.lowerBound])
            }
        default: kind = .other
        }
        guard !name.isEmpty else { return nil }
        return RemoteFile(
            name: name, path: RemotePath.join(directory, name), kind: kind,
            size: Int64(fields[4]) ?? 0, modified: modified, permissions: String(fields[0]),
            owner: String(fields[2]), linkTarget: target
        )
    }

    static func date(month: String, day: String, timeOrYear: String, now: Date) -> Date? {
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let monthIndex = months.firstIndex(of: String(month.lowercased().prefix(3))), let day = Int(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = DateComponents(month: monthIndex + 1, day: day)
        if timeOrYear.contains(":") {
            let parts = timeOrYear.split(separator: ":")
            components.hour = Int(parts[0])
            components.minute = parts.count > 1 ? Int(parts[1]) : 0
            let year = calendar.component(.year, from: now)
            components.year = year
            // Sans année : les 6 derniers mois. Une date dans le futur est de l'année passée.
            if let date = calendar.date(from: components), date > now.addingTimeInterval(86_400) {
                components.year = year - 1
            }
        } else {
            components.year = Int(timeOrYear)
        }
        return calendar.date(from: components)
    }
}

// MARK: - Commandes ssh / scp

/// Construit les commandes `ssh` et `scp` vers une connexion. Pas de mot de passe :
/// `BatchMode` (les clés et l'agent seulement), et une connexion partagée pour aller vite.
public struct SSHCommands: Sendable {
    public let alias: String
    public let controlDirectory: String

    public init(alias: String, controlDirectory: String = SSHCommands.defaultControlDirectory) {
        self.alias = alias
        self.controlDirectory = controlDirectory
    }

    /// Chemin court : les sockets Unix sont limités à 104 caractères.
    public static var defaultControlDirectory: String { "/tmp/latelier-ssh-\(getuid())" }

    public static func prepareControlDirectory(_ path: String = defaultControlDirectory) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    public var options: [String] {
        [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15",
            "-o", "ControlMaster=auto", "-o", String(localized: "ControlPath=\(controlDirectory)/%C"), "-o", "ControlPersist=120",
        ]
    }

    /// `ssh … -- alias '<commande>'` : la commande est interprétée par le shell du serveur.
    public func ssh(_ remoteCommand: String) -> CommandSpec {
        CommandSpec("/usr/bin/ssh", options + ["--", alias, remoteCommand])
    }

    /// Chemin source passé à scp : scp (mode SFTP) développe les jokers des sources, on les protège.
    /// Une destination, elle, est prise telle quelle (ne pas la protéger).
    public static func scpPath(_ path: String) -> String {
        var result = ""
        for character in path {
            if "*?[]\\".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    public func download(_ remotePaths: [String], to folder: URL) -> CommandSpec {
        CommandSpec("/usr/bin/scp", ["-r", "-p", "-q"] + options + ["--"] + remotePaths.map { "\(alias):\(Self.scpPath($0))" } + [folder.path + "/"])
    }

    public func upload(_ files: [URL], to remoteDirectory: String) -> CommandSpec {
        let target = remoteDirectory.hasSuffix("/") ? remoteDirectory : remoteDirectory + "/"
        return CommandSpec("/usr/bin/scp", ["-r", "-p", "-q"] + options + ["--"] + files.map(\.path) + ["\(alias):\(target)"])
    }

    /// Envoie un fichier à un emplacement précis (enregistrement d'un fichier modifié).
    public func put(_ file: URL, as remotePath: String) -> CommandSpec {
        CommandSpec("/usr/bin/scp", ["-p", "-q"] + options + ["--", file.path, "\(alias):\(remotePath)"])
    }

    public func fetch(_ remotePath: String, to file: URL) -> CommandSpec {
        CommandSpec("/usr/bin/scp", ["-p", "-q"] + options + ["--", "\(alias):\(Self.scpPath(remotePath))", file.path])
    }

    public func list(_ directory: String) -> CommandSpec {
        let quoted = ShellQuote.quote(directory)
        return ssh("cd -- \(quoted) && { LC_ALL=C ls -la --time-style=+%s 2>/dev/null || LC_ALL=C ls -la; }")
    }

    public var home: CommandSpec { ssh("pwd") }

    public func makeDirectory(_ path: String) -> CommandSpec { ssh("mkdir -- \(ShellQuote.quote(path))") }

    /// Renomme sans écraser : refuse si la cible existe.
    public func rename(_ path: String, to newPath: String) -> CommandSpec {
        let target = ShellQuote.quote(newPath)
        // Le nom n'entre dans le script que quoté (il peut contenir " $ ` …) ; mv -n ferme la course test → mv.
        let message = ShellQuote.quote(String(localized: "« \(newPath) » existe déjà : rien n’a été renommé."))
        return ssh("if [ -e \(target) ] || [ -L \(target) ]; then printf '%s\\n' \(message) >&2; exit 1; fi; mv -n -- \(ShellQuote.quote(path)) \(target) && [ ! -e \(ShellQuote.quote(path)) ]")
    }

    /// Corbeille du serveur : `~/.latelier-corbeille/<date>/`, récupérable à la main.
    /// Un sous-dossier unique par mise à la corbeille (mktemp) : deux fichiers homonymes ne s'écrasent jamais.
    public func trash(_ paths: [String], stamp: String) -> CommandSpec {
        let base = "\"$HOME\"/.latelier-corbeille"
        return ssh("mkdir -p \(base) && d=$(mktemp -d \(base)/\(ShellQuote.quote(stamp + "-XXXXXX"))) && mv -n -- \(paths.map(ShellQuote.quote).joined(separator: " ")) \"$d\"/ && echo \"$d\"")
    }

    /// Noms (parmi `names`) qui existent déjà dans `directory`, vérifiés sur le serveur au moment voulu.
    public func existing(_ names: [String], in directory: String) -> CommandSpec {
        let checks = names.map { name in
            let path = ShellQuote.quote(RemotePath.join(directory, name))
            return String(localized: "if [ -e \(path) ] || [ -L \(path) ]; then printf '%s\\n' \(ShellQuote.quote(name)); fi")
        }
        return ssh(checks.joined(separator: "; ") + "; true")
    }

    /// Remplace le contenu d'un fichier par `uploaded` (déjà envoyé à côté), seulement si le fichier
    /// n'a pas changé depuis son ouverture (`expected` = ligne `ls -ld` d'alors). `cat >` garde les droits,
    /// le propriétaire et le bit exécutable du fichier d'origine.
    public func replace(_ path: String, with uploaded: String, ifUnchanged expected: String) -> CommandSpec {
        let target = ShellQuote.quote(path)
        let temp = ShellQuote.quote(uploaded)
        let now = "$(LC_ALL=C ls -ld --time-style=+%s -- \(target) 2>/dev/null || LC_ALL=C ls -ld -- \(target))"
        let changed = ShellQuote.quote(String(localized: "Le fichier a été modifié sur le serveur entre-temps : rien n’a été remplacé."))
        return ssh("if [ \"\(now)\" != \(ShellQuote.quote(expected)) ]; then rm -f -- \(temp); printf '%s\\n' \(changed) >&2; exit 1; fi; cat -- \(temp) > \(target) && rm -f -- \(temp)")
    }

    public func delete(_ paths: [String]) -> CommandSpec {
        ssh("rm -rf -- \(paths.map(ShellQuote.quote).joined(separator: " "))")
    }

    /// Taille et date d'un fichier (pour savoir s'il a changé avant d'enregistrer).
    public func stat(_ path: String) -> CommandSpec {
        let quoted = ShellQuote.quote(path)
        return ssh("LC_ALL=C ls -ld --time-style=+%s -- \(quoted) 2>/dev/null || LC_ALL=C ls -ld -- \(quoted)")
    }

    public var test: CommandSpec { ssh("echo ok") }

    /// Ligne de commande pour le terminal (interactive : mot de passe et empreinte possibles).
    public func interactive(directory: String? = nil) -> [String] {
        guard let directory else { return ["ssh", alias] }
        return ["ssh", "-t", alias, String(localized: "cd \(ShellQuote.quote(directory)) && exec \"$SHELL\" -l")]
    }

    /// Commande distante dans le terminal (sudo, journaux en direct) : `ssh -t alias '<commande>'`.
    public func interactive(remote command: String) -> [String] {
        ["ssh", "-t", alias, command]
    }

    /// Ferme la connexion partagée.
    public var closeMaster: CommandSpec {
        CommandSpec("/usr/bin/ssh", options + ["-O", "exit", "--", alias])
    }
}

/// Explique en clair un échec de ssh.
public enum SSHFailure {
    public static func explain(_ output: String) -> (title: String, advice: String) {
        let text = output.lowercased()
        if text.contains("permission denied") {
            return (String(localized: "Accès refusé"), String(localized: "Le serveur n’accepte pas votre clé. L’explorateur n’utilise que les clés SSH (pas de mot de passe) : installez votre clé avec « Installer ma clé » ou connectez-vous une fois dans le terminal."))
        }
        if text.contains("host key verification failed") || text.contains("remote host identification has changed") {
            return (String(localized: "Empreinte du serveur inconnue ou changée"), String(localized: "Connectez-vous une fois dans le terminal pour vérifier et accepter l’empreinte du serveur."))
        }
        if text.contains("could not resolve hostname") || text.contains("nodename nor servname") {
            return (String(localized: "Adresse introuvable"), String(localized: "Le nom du serveur ne correspond à aucune adresse. Vérifiez « Adresse » dans la connexion, ou votre VPN."))
        }
        if text.contains("no route to host") || text.contains("network is unreachable") || text.contains("host is down") {
            return (String(localized: "Serveur injoignable"), String(localized: "Aucun chemin réseau vers ce serveur : il est éteint, ou il est sur un autre réseau (domicile, VPN) que ce Mac."))
        }
        if text.contains("timed out") {
            return (String(localized: "Le serveur ne répond pas"), String(localized: "Délai dépassé. Le serveur est éteint, ou un pare-feu/VPN bloque la connexion."))
        }
        if text.contains("connection refused") {
            return (String(localized: "Connexion refusée"), String(localized: "Le serveur répond mais n’accepte pas SSH sur ce port. Vérifiez le port."))
        }
        if text.contains("no such file or directory") {
            return (String(localized: "Introuvable"), String(localized: "Ce fichier ou dossier n’existe pas (ou plus) sur le serveur."))
        }
        let last = output.split(separator: "\n").last.map(String.init) ?? output
        return (String(localized: "Échec de la connexion"), last.trimmingCharacters(in: .whitespaces))
    }
}
