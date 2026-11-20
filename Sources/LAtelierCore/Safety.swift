import Foundation

/// Règle de sécurité n° 4 : on ne supprime jamais hors du dossier personnel,
/// ni un dossier système ou sensible, même si on nous le demande.
public struct SafetyGuard: Sendable {
    public enum Refusal: Error, LocalizedError, Equatable {
        case outsideAllowedRoot(String)
        case protectedLocation(String)

        public var errorDescription: String? {
            switch self {
            case .outsideAllowedRoot(let path): String(localized: "Refusé : « \(path) » est hors du dossier personnel.")
            case .protectedLocation(let path): String(localized: "Refusé : « \(path) » est un emplacement protégé.")
            }
        }
    }

    public let root: URL
    private let protectedExact: Set<String>
    private let protectedTrees: [String]

    public static let standard = SafetyGuard(root: URL(fileURLWithPath: NSHomeDirectory()))

    public init(root: URL) {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        self.root = URL(fileURLWithPath: base)
        let exact = [
            "", "Library", "Library/Caches", "Library/Logs", "Library/Application Support",
            "Library/Preferences", "Library/Containers", "Library/Group Containers", "Documents",
            "Desktop", "Downloads", "Pictures", "Music", "Movies", "Applications", "Public", ".Trash",
            "projects", "Projects", "Developer", "dev", "code", "src", "work",
        ]
        self.protectedExact = Set(exact.map { $0.isEmpty ? base : "\(base)/\($0)" })
        self.protectedTrees = [".ssh", ".gnupg", "Library/Keychains", "Library/Mobile Documents", "Library/Mail", "Library/Messages"]
            .map { "\(base)/\($0)" }
    }

    /// `/Applications/Nom.app` ou `~/Applications/Nom.app`, sans sous-dossier (Utilities est exclu).
    public static func isApplicationBundle(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        let name = url.lastPathComponent
        return name.hasSuffix(".app") && name.count > 4 && !name.hasPrefix(".")
            && (parent == "/Applications" || parent == home + "/Applications")
    }

    /// Fichier que L’Atelier peut réécrire (jamais supprimer) : comme `check`,
    /// plus `~/.ssh/config`, le seul fichier modifiable de ~/.ssh.
    public func checkEditable(_ url: URL) throws {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        if parent == root.path + "/.ssh", url.lastPathComponent == "config" { return }
        try check(url)
    }

    /// Lève une erreur si l'élément ne doit pas être supprimé.
    public func check(_ url: URL) throws {
        // On résout les liens du dossier parent (pas de l'élément : supprimer un lien ne touche que le lien).
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let path = (parent as NSString).appendingPathComponent(url.lastPathComponent)
        let base = root.path
        // Une app installée, directement dans /Applications (Désinstalleur) : jamais un dossier système.
        if Self.isApplicationBundle(path) { return }
        guard path.hasPrefix(base + "/"), !url.lastPathComponent.isEmpty, url.lastPathComponent != ".." else {
            throw Refusal.outsideAllowedRoot(url.path)
        }
        if protectedExact.contains(path) || protectedTrees.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            throw Refusal.protectedLocation(url.path)
        }
    }
}
