import Foundation

/// Règle de sécurité n° 4 : on ne supprime jamais hors du dossier personnel,
/// ni un dossier système ou sensible, même si on nous le demande.
public struct SafetyGuard: Sendable {
    public enum Refusal: Error, LocalizedError, Equatable {
        case outsideAllowedRoot(String)
        case protectedLocation(String)

        public var errorDescription: String? {
            switch self {
            case .outsideAllowedRoot(let path): "Refusé : « \(path) » est hors du dossier personnel."
            case .protectedLocation(let path): "Refusé : « \(path) » est un emplacement protégé."
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

    /// Lève une erreur si l'élément ne doit pas être supprimé.
    public func check(_ url: URL) throws {
        // On résout les liens du dossier parent (pas de l'élément : supprimer un lien ne touche que le lien).
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let path = (parent as NSString).appendingPathComponent(url.lastPathComponent)
        let base = root.path
        guard path.hasPrefix(base + "/"), !url.lastPathComponent.isEmpty, url.lastPathComponent != ".." else {
            throw Refusal.outsideAllowedRoot(url.path)
        }
        if protectedExact.contains(path) || protectedTrees.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            throw Refusal.protectedLocation(url.path)
        }
    }
}
