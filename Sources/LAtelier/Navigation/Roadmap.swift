/// Ce que chaque écran pas encore construit contiendra, et à quelle étape (voir project.md).
struct Roadmap {
    let step: Int
    let features: [String]

    static func of(_ page: Page) -> Roadmap? {
        switch page {
        case .stockageVue:
            Roadmap(step: 9, features: [
                "Répartition du disque entier : macOS, données système, apps, développeur, images, musique…",
                "Ce qui est récupérable dans chaque catégorie, avec un lien vers l’écran qui s’en charge",
            ])
        case .systeme:
            Roadmap(step: 2, features: ["Caches et journaux utilisateur", "Fichiers temporaires", "Aperçu puis corbeille"])
        case .appsNettoyage:
            Roadmap(step: 9, features: ["Restes d’apps déjà supprimées", "Caches et réglages orphelins"])
        case .desinstalleur:
            Roadmap(step: 9, features: ["Désinstaller une app avec tous ses fichiers associés", "Refus si l’app est ouverte"])
        case .docker:
            Roadmap(step: 9, features: ["Images, conteneurs arrêtés, volumes orphelins, cache de build", "Rien de ce qui tourne"])
        case .dev:
            Roadmap(step: 2, features: ["node_modules, target, build, DerivedData, .venv…", "Classés par projet et par ancienneté"])
        case .caches:
            Roadmap(step: 9, features: ["Caches npm, pnpm, yarn, pip, cargo, Gradle, Maven, Homebrew, CocoaPods"])
        case .explorateur:
            Roadmap(step: 9, features: ["Arborescence triée par taille", "Aperçu et envoi à la corbeille"])
        case .sonar:
            Roadmap(step: 9, features: ["Radar des fichiers vieux, lourds ou en double", "Garder / Corbeille / Passer, avec objectif d’espace libéré"])
        case .depots:
            Roadmap(step: 3, features: ["Détection des dépôts git dans tes dossiers", "Branche, avance / retard, état", "Fetch, pull, push avec aperçu", "Ouvrir dans Claude, le terminal ou l’éditeur"])
        case .modifications:
            Roadmap(step: 3, features: ["Fichiers modifiés, diff, indexation", "Commit et stash avec aperçu"])
        case .commandes:
            Roadmap(step: 7, features: ["Commandes détectées (package.json, Makefile, Cargo, Maven…)", "Console en direct", "Suggestions de commandes utiles"])
        case .dependances:
            Roadmap(step: 5, features: ["Dépendances de chaque projet", "Versions obsolètes et mises à jour possibles"])
        case .securite:
            Roadmap(step: 5, features: ["Vulnérabilités connues (OSV)", "Correction proposée, ou confiée à Claude"])
        case .couverture:
            Roadmap(step: 7, features: ["Lecture des rapports lcov, Cobertura, JaCoCo, xccov", "Évolution dans le temps et fichiers les moins couverts"])
        case .majs:
            Roadmap(step: 4, features: ["Paquets obsolètes de toutes les sources", "Mise à jour unitaire ou groupée, avec aperçu"])
        case .inventaire:
            Roadmap(step: 4, features: ["Homebrew, npm global, pip, cargo, gems…", "Recherche et filtre par source"])
        case .runtimes:
            Roadmap(step: 4, features: ["Versions de Node, Python, Java, Ruby… installées", "Fin de support (endoflife.date)"])
        case .services:
            Roadmap(step: 4, features: ["Services Homebrew et agents de lancement", "Démarrer, arrêter, redémarrer"])
        case .perfVue:
            Roadmap(step: 6, features: ["CPU, mémoire, GPU, disque, réseau en temps réel", "Pression mémoire et température"])
        case .processus:
            Roadmap(step: 6, features: ["Liste triable des processus, regroupés par app", "Quitter ou forcer à quitter"])
        case .reseau:
            Roadmap(step: 6, features: ["Débit par interface", "Ports ouverts et processus qui écoutent"])
        case .demarrage:
            Roadmap(step: 6, features: ["Éléments d’ouverture et agents en arrière-plan", "Activer ou désactiver"])
        case .enregistreur:
            Roadmap(step: 7, features: ["Détection automatique des processus lancés dans un projet", "Enregistrement CPU / mémoire, repères, comparaison de sessions"])
        case .pourVous:
            Roadmap(step: 8, features: ["Fil d’actualité selon tes langages et tes paquets"])
        case .cyber:
            Roadmap(step: 8, features: ["CISA KEV, CERT-FR, avis GitHub", "Alerte si un paquet installé est concerné"])
        case .langages:
            Roadmap(step: 8, features: ["Sorties et changements de tes langages"])
        case .favoris:
            Roadmap(step: 8, features: ["Articles gardés pour plus tard"])
        case .sources:
            Roadmap(step: 8, features: ["Flux RSS / Atom, ajout et désactivation"])
        case .accueil, .historique, .reglages:
            nil
        }
    }
}
