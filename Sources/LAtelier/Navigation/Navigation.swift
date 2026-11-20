import SwiftUI

/// Les grandes sections de la barre latérale (accordéon).
enum SidebarGroup: String, CaseIterable, Identifiable {
    case stockage, projets, paquets, performance, news

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stockage: "Stockage"
        case .projets: "Projets"
        case .paquets: "Paquets"
        case .performance: "Performance"
        case .news: "News"
        }
    }

    var symbol: String {
        switch self {
        case .stockage: "internaldrive"
        case .projets: "folder.badge.gearshape"
        case .paquets: "cube.box"
        case .performance: "gauge.with.dots.needle.67percent"
        case .news: "newspaper"
        }
    }

    var tint: Color {
        switch self {
        case .stockage: .blue
        case .projets: .orange
        case .paquets: .purple
        case .performance: .green
        case .news: .pink
        }
    }

    var tagline: String {
        switch self {
        case .stockage: "Ce qui occupe le disque, et ce qu’on peut libérer sans risque."
        case .projets: "Dépôts git, commandes, dépendances, sécurité et couverture."
        case .paquets: "Tout ce qui est installé, ce qui est obsolète, les mises à jour."
        case .performance: "Le gestionnaire des tâches : CPU, mémoire, GPU, réseau, processus."
        case .news: "L’actualité de tes langages et la cybersécurité qui te concerne."
        }
    }

    /// Lignes de la barre latérale, dans l'ordre. Un sous-groupe a un titre non sélectionnable.
    var entries: [SidebarEntry] {
        switch self {
        case .stockage:
            [.page(.stockageVue), .page(.systeme), .sub("Applications", [.appsNettoyage, .desinstalleur]),
             .page(.docker), .page(.dev), .page(.caches), .page(.explorateur), .page(.sonar)]
        case .projets:
            [.page(.depots), .page(.modifications), .page(.commandes), .page(.dependances),
             .page(.securite), .page(.couverture)]
        case .paquets:
            [.page(.majs), .page(.inventaire), .page(.runtimes), .page(.services)]
        case .performance:
            [.page(.perfVue), .page(.moniteur), .page(.processus), .page(.reseau), .page(.demarrage), .page(.enregistreur)]
        case .news:
            [.page(.pourVous), .page(.cyber), .page(.langages), .page(.favoris), .page(.sources)]
        }
    }

    var pages: [Page] {
        entries.flatMap { entry -> [Page] in
            switch entry {
            case .page(let page): [page]
            case .sub(_, let pages): pages
            }
        }
    }

    var firstPage: Page { pages[0] }
}

enum SidebarEntry: Hashable {
    case page(Page)
    case sub(String, [Page])
}

/// Chaque écran de l'app.
enum Page: String, CaseIterable, Identifiable {
    case accueil
    // Stockage
    case stockageVue, systeme, appsNettoyage, desinstalleur, docker, dev, caches, explorateur, sonar
    // Projets
    case depots, modifications, commandes, dependances, securite, couverture
    // Paquets
    case majs, inventaire, runtimes, services
    // Performance
    case perfVue, moniteur, processus, reseau, demarrage, enregistreur
    // News
    case pourVous, cyber, langages, favoris, sources
    // Bas de barre
    case historique, reglages

    var id: String { rawValue }

    var group: SidebarGroup? {
        SidebarGroup.allCases.first { $0.pages.contains(self) }
    }

    var title: String {
        switch self {
        case .accueil: "Accueil"
        case .stockageVue: "Vue d’ensemble"
        case .systeme: "Système"
        case .appsNettoyage: "Nettoyage"
        case .desinstalleur: "Désinstalleur"
        case .docker: "Docker"
        case .dev: "Développement"
        case .caches: "Caches"
        case .explorateur: "Explorateur"
        case .sonar: "Sonar"
        case .depots: "Dépôts"
        case .modifications: "Modifications"
        case .commandes: "Commandes"
        case .dependances: "Dépendances"
        case .securite: "Sécurité"
        case .couverture: "Couverture"
        case .majs: "Mises à jour"
        case .inventaire: "Inventaire"
        case .runtimes: "Runtimes"
        case .services: "Services"
        case .perfVue: "Vue d’ensemble"
        case .moniteur: "Moniteur"
        case .processus: "Processus"
        case .reseau: "Réseau"
        case .demarrage: "Démarrage"
        case .enregistreur: "Enregistreur"
        case .pourVous: "Pour vous"
        case .cyber: "Cybersécurité"
        case .langages: "Langages"
        case .favoris: "Favoris"
        case .sources: "Sources"
        case .historique: "Historique"
        case .reglages: "Réglages"
        }
    }

    /// Titre complet pour l'en-tête, avec le parent quand il aide (« Applications · Nettoyage »).
    var headerTitle: String {
        switch self {
        case .appsNettoyage, .desinstalleur: "Applications · \(title)"
        case .stockageVue, .perfVue: "\(group!.title) · \(title)"
        case .pourVous: "News · pour vous"
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .accueil: "house"
        case .stockageVue: "chart.pie"
        case .systeme: "gearshape.2"
        case .appsNettoyage: "sparkles"
        case .desinstalleur: "trash.square"
        case .docker: "shippingbox"
        case .dev: "hammer"
        case .caches: "archivebox"
        case .explorateur: "folder"
        case .sonar: "dot.radiowaves.left.and.right"
        case .depots: "arrow.triangle.branch"
        case .modifications: "plus.forwardslash.minus"
        case .commandes: "terminal"
        case .dependances: "point.3.connected.trianglepath.dotted"
        case .securite: "lock.shield"
        case .couverture: "checkmark.seal"
        case .majs: "arrow.down.circle"
        case .inventaire: "list.bullet.rectangle"
        case .runtimes: "chevron.left.forwardslash.chevron.right"
        case .services: "server.rack"
        case .perfVue: "gauge.with.dots.needle.67percent"
        case .moniteur: "waveform.path.ecg.rectangle"
        case .processus: "list.number"
        case .reseau: "network"
        case .demarrage: "power"
        case .enregistreur: "record.circle"
        case .pourVous: "sparkles.rectangle.stack"
        case .cyber: "exclamationmark.shield"
        case .langages: "curlybraces"
        case .favoris: "star"
        case .sources: "dot.radiowaves.up.forward"
        case .historique: "clock.arrow.circlepath"
        case .reglages: "gearshape"
        }
    }

    var tint: Color { group?.tint ?? .accentColor }
}
