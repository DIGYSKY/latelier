# Journal des versions

<sub>[English](CHANGELOG.md) · **Français**</sub>

Les changements notables de L’Atelier sont listés ici. Les versions suivent le [versionnage sémantique](https://semver.org/lang/fr/).

## [1.0.0-beta.1] — 2026-11-20

Première bêta publique.

### Stockage
- Vue d’ensemble du disque entier, avec le détail de « Autres ».
- Artefacts de développement, caches de paquets (vidés par la commande de chaque outil), Docker, restes d’apps, désinstalleur.
- Sonar (plus gros fichiers et doublons) et explorateur dossier par dossier.

### Projets
- Tous les dépôts git du Mac, triés par activité, avec une page par dépôt : git, commandes, dépendances, failles, couverture de tests.
- La pastille de Projets compte les **projets actifs touchés par une faille critique**.

### Serveurs
- Connexions SSH de `~/.ssh/config` : ajouter, modifier, dupliquer, supprimer, sans rien perdre du reste du fichier (commentaires, `Host *`, `Match`, `Include`, fichier en lien symbolique).
- Terminal en un clic, explorateur de fichiers distant avec éditeur intégré, corbeille côté serveur.
- Moniteur sans agent : processeur, mémoire, disques, réseau, processus, services systemd, conteneurs Docker, ports ; arrêter un processus, redémarrer un service ou un conteneur (avec aperçu ; `sudo` se fait dans votre terminal).

### Paquets, Performance, News
- Inventaire et mises à jour des paquets, runtimes, services Homebrew.
- Moniteur en direct, processus, réseau, démarrage, enregistreur des processus de dev.
- Actualités de vos langages et avis de sécurité croisés avec ce qui est installé.

### Partout
- Premier lancement guidé, français et anglais, menu dans la barre des menus, historique de chaque action.
- Signaler un problème depuis l’app (issue GitHub pré-remplie, chemins personnels masqués).
- Mises à jour depuis les releases GitHub : empreinte et signature vérifiées, la version actuelle est remise en place en cas d’échec.
- Réglages › À propos : licence, données sur le Mac, désinstallation propre.
