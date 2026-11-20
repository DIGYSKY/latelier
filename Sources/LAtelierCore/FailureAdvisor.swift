import Foundation

/// Explication d'un échec connu, et ce qui le corrige.
public struct FailureHint: Sendable, Equatable {
    public var title: String
    public var explanation: String
    /// Correction proposée (passe par l'aperçu), avec son libellé.
    public var fixLabel: String?
    public var fix: CommandSpec?
    /// Écran de L’Atelier où l'on corrige (« runtimes »), sans commande directe.
    public var page: String?

    public init(title: String, explanation: String, fixLabel: String? = nil, fix: CommandSpec? = nil, page: String? = nil) {
        self.title = title
        self.explanation = explanation
        self.fixLabel = fixLabel
        self.fix = fix
        self.page = page
    }
}

/// Reconnaît les erreurs courantes dans la sortie d'une commande et dit quoi faire.
public enum FailureAdvisor {
    public static func hint(for output: String, nvmRoot: URL = Nvm.root()) -> FailureHint? {
        // npm : version de Node refusée par le projet (engine-strict).
        if output.contains("EBADENGINE") || output.contains("Unsupported engine") {
            let required = capture(#"Required:\s*\{"node":"([^"]+)""#, in: output)
            let actual = capture(#"Actual:\s*\{"node":"v?([^"]+)""#, in: output)
            let package = capture(#"Not compatible with your version of node/npm: (\S+)"#, in: output)
            let major = actual.flatMap { $0.split(separator: ".").first.map(String.init) } ?? "lts/*"
            var text = String(localized: "Le projet")
            if let package { text += String(localized: " (via \(package))") }
            text += String(localized: " demande Node \(required ?? String(localized: "plus récent"))")
            if let actual { text += String(localized: ", mais Node \(actual) est utilisé") }
            text += ". Le fichier .npmrc du projet (engine-strict) transforme cet avertissement en erreur."
            text += String(localized: " Installez une version compatible, puis relancez L’Atelier pour qu’il l’utilise.")
            return FailureHint(
                title: String(localized: "Version de Node trop ancienne"), explanation: text,
                fixLabel: String(localized: "Installer la dernière Node \(major)…"), fix: Nvm.command(["install", major], root: nvmRoot), page: "runtimes"
            )
        }
        // Corepack a téléchargé une version de pnpm / yarn que le Corepack de Node ne sait pas lancer.
        if let tool = capture(#"Cannot find module '[^']*/corepack/v1/(pnpm|yarn)/[^']+'"#, in: output) {
            let version = capture(#"/corepack/v1/(?:pnpm|yarn)/([0-9.]+)/"#, in: output) ?? "?"
            let major = Int(version.split(separator: ".").first ?? "") ?? 0
            let pin = tool == "pnpm" ? "10" : "1"
            return FailureHint(
                title: String(localized: "\(tool) \(version) ne fonctionne pas avec ce Corepack"),
                explanation: String(localized: "Corepack (fourni avec Node) a téléchargé \(tool) \(version), dont les fichiers ne sont plus organisés comme il l’attend. Revenez à une version compatible, ou remettez le dossier ~/.cache/node/corepack depuis la corbeille s’il vient d’y partir."),
                fixLabel: major > Int(pin)! ? String(localized: "Revenir à \(tool) \(pin)…") : nil,
                fix: major > Int(pin)! ? CommandSpec("corepack", ["install", "-g", "\(tool)@\(pin)"]) : nil
            )
        }
        // Un fichier d'outil (chemin absolu) a disparu : ce n'est pas une dépendance du projet.
        if let path = capture(#"Cannot find module '(/[^']+)'"#, in: output) {
            return FailureHint(title: String(localized: "Fichier d’outil introuvable"),
                               explanation: String(localized: "L’outil cherche \(path), qui n’existe plus. Son installation est incomplète : réinstallez l’outil, ou remettez depuis la corbeille ce qui vient d’y partir."))
        }
        // Vitest sans module de couverture, et autres dépendances absentes.
        if let missing = capture(#"Cannot find (?:dependency|module) '([^']+)'"#, in: output) {
            return FailureHint(title: String(localized: "Dépendance manquante : \(missing)"),
                               explanation: String(localized: "Le projet utilise \(missing) sans l’avoir dans ses dépendances (ou node_modules n’est pas installé). Ajoutez-la, ou lancez l’installation des dépendances du projet."))
        }
        // Homebrew refuse de retirer une formule requise par une autre.
        if let users = capture(#"because it is required by ([^,]+), which (?:is|are) currently installed"#, in: output) {
            return FailureHint(title: String(localized: "Requis par \(users)"),
                               explanation: String(localized: "Homebrew garde ce paquet parce que \(users) en dépend. Désinstallez d’abord \(users), ou gardez-le."),
                               page: "inventaire")
        }
        if output.contains("command not found") || output.contains("No such file or directory") && output.contains("env:") {
            let tool = capture(#"(?:zsh|bash|env): (?:command not found: )?([^\s:]+)"#, in: output)
            return FailureHint(title: String(localized: "Outil introuvable") + (tool.map { " : \($0)" } ?? ""),
                               explanation: String(localized: "La commande n’existe pas sur cette machine, ou pas dans les dossiers où L’Atelier la cherche. Vérifiez Réglages › Général › Outils de développement."),
                               page: "reglages")
        }
        if output.contains("EACCES") || output.contains("Permission denied") || output.contains("Operation not permitted") {
            return FailureHint(title: String(localized: "Accès refusé"),
                               explanation: String(localized: "macOS ou les droits du fichier ont bloqué l’opération. Un dossier protégé (Documents, conteneur d’app) demande l’accès complet au disque ; un dossier système demande les droits administrateur."))
        }
        if output.contains("Please commit your changes or stash them") || output.contains("would be overwritten by merge") {
            return FailureHint(title: String(localized: "Modifications locales en cours"),
                               explanation: String(localized: "Git refuse pour ne pas écraser vos fichiers modifiés. Committez-les ou mettez-les de côté (stash), puis recommencez."))
        }
        if output.contains("Could not resolve host") || output.contains("ENOTFOUND") || output.contains("getaddrinfo") || output.contains("Network is unreachable") {
            return FailureHint(title: String(localized: "Pas de connexion"),
                               explanation: String(localized: "Le serveur n’a pas pu être joint. Vérifiez la connexion (ou le VPN), puis recommencez."))
        }
        if output.contains("ERESOLVE") {
            return FailureHint(title: String(localized: "Conflit de versions npm"),
                               explanation: String(localized: "npm ne trouve pas de combinaison de versions compatible (peer dependencies). Alignez les versions concernées, ou relancez avec --legacy-peer-deps dans un terminal si vous savez ce que vous faites."))
        }
        return nil
    }

    public static func hint(for entry: HistoryEntry) -> FailureHint? {
        guard entry.outcome != .success, entry.outcome != .cancelled else { return nil }
        return hint(for: entry.commands.map(\.output).joined(separator: "\n"))
    }

    static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
