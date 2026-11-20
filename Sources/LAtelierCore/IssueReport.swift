import Foundation

/// Lien « Signaler un problème » : ouvre une issue GitHub pré-remplie avec la version de l'app et de macOS.
/// Rien n'est envoyé par L’Atelier : c'est la page GitHub qui s'ouvre, et vous relisez avant de publier.
public enum IssueReport {
    public enum Kind: String, Sendable {
        case bug = "bug_report.yml"
        case idea = "feature_request.yml"
    }

    public struct Environment: Sendable, Equatable {
        public var appVersion: String
        public var build: String
        public var macOS: String
        public var architecture: String
        public var installation: String
        public var language: String

        public init(appVersion: String, build: String, macOS: String, architecture: String, installation: String, language: String) {
            self.appVersion = appVersion
            self.build = build
            self.macOS = macOS
            self.architecture = architecture
            self.installation = installation
            self.language = language
        }

        /// Une ligne par information, à coller dans une issue.
        public var summary: String {
            "L’Atelier \(appVersion) (\(build)) · macOS \(macOS) · \(architecture) · \(installation) · \(language)"
        }
    }

    /// `https://github.com/<dépôt>/issues/new?template=…&version=…` (les champs du formulaire sont pré-remplis).
    public static func url(repository: String, kind: Kind, environment: Environment, details: String? = nil) -> URL? {
        var components = URLComponents(string: "https://github.com/\(repository)/issues/new")
        var items = [URLQueryItem(name: "template", value: kind.rawValue)]
        if kind == .bug {
            items += [
                URLQueryItem(name: "version", value: "\(environment.appVersion) (\(environment.build))"),
                URLQueryItem(name: "macos", value: "\(environment.macOS) · \(environment.architecture)"),
                URLQueryItem(name: "install", value: environment.installation),
            ]
            if let details, !details.isEmpty {
                // GitHub limite la longueur d'une URL : on garde la fin, la plus utile.
                items.append(URLQueryItem(name: "logs", value: String(details.suffix(4_000))))
            }
        }
        components?.queryItems = items
        return components?.url
    }

    /// Retire ce qui identifie la personne : le dossier personnel devient `~`, le nom du compte `<utilisateur>`.
    public static func redact(_ text: String, home: String = NSHomeDirectory(), user: String = NSUserName()) -> String {
        var result = text.replacingOccurrences(of: home, with: "~")
        if user.count >= 3 {
            result = result.replacingOccurrences(of: user, with: "<utilisateur>")
        }
        return result
    }
}
