# Journal des versions

<sub>[English](CHANGELOG.md) · **Français**</sub>

Les changements notables de L’Atelier sont listés ici. Les versions suivent le [versionnage sémantique](https://semver.org/lang/fr/).

## [1.0.0-beta.4] — 2026-11-20

### Corrigé
- **Les sous-paquets vulnérables sont vraiment corrigés.** Un paquet absent de `package.json` mais demandé par un autre (par exemple `proxy-addr`, demandé par `express`) restait vulnérable : avec yarn 1, `yarn upgrade` ne fait rien pour un sous-paquet, et l’action était tout de même notée réussie. Son entrée est maintenant retirée du `yarn.lock`, puis `yarn install` prend la version corrigée que permet le parent.
- **Fini les faux succès.** Après une correction de faille, L’Atelier relit le lockfile : une version toujours vulnérable est signalée dans l’historique au lieu d’un ✓.

### Amélioré
- **D’où vient un sous-paquet.** Les lignes de sécurité indiquent « sous-paquet de express », quel parent le demande et avec quel intervalle.
- **Versions bloquées par un parent.** Quand l’intervalle du parent exclut la version corrigée, L’Atelier le dit et propose **Forcer x…** : la version est ajoutée à `resolutions` (yarn) ou `overrides` (npm) dans `package.json`, puis réinstallée, avec aperçu avant. Si d’autres versions majeures du même paquet sont utilisées, rien n’est forcé et le parent à mettre à jour est nommé.

## [1.0.0-beta.3] — 2026-11-20

### Corrigé
- **Plus de mot de passe administrateur au lancement.** La lecture des éléments de connexion (`sfltool`, protégé par macOS) se faisait pendant « Tout analyser au démarrage » : macOS demandait le mot de passe administrateur à chaque lancement. Ces éléments ne sont plus lus que sur demande, depuis Performance › Démarrage.

### Amélioré
- **Des mises à jour plus claires.** L’aperçu montre la nouvelle et l’actuelle version, avec un bouton « Installer la mise à jour », et se termine par « L’Atelier x est installé » et **Redémarrer maintenant** / **Plus tard**. Si vous choisissez Plus tard, un bandeau sur l’Accueil rappelle de redémarrer.

## [1.0.0-beta.2] — 2026-11-20

### Corrigé
- **Caches** : nettoyer le cache de Corepack (`~/.cache/node/corepack`) pouvait casser pnpm. Sans lui, Corepack télécharge le dernier pnpm (12), que le Corepack fourni avec Node 22 ne sait pas lancer. Ce cache est désormais « À vérifier » et n’est plus coché par défaut.
- **Ordre du nettoyage** : les commandes des outils (`pnpm store prune`…) passent avant la mise à la corbeille des fichiers : un cache retiré ne peut plus casser un outil qui doit encore tourner.
- **Explication des échecs** : une version de pnpm/yarn que Corepack ne sait pas lancer est reconnue, avec la correction « Revenir à pnpm 10… » ; un fichier d’outil manquant n’est plus présenté comme une dépendance du projet.

> Si pnpm ne fonctionne plus après un nettoyage avec la bêta 1 : lancez `corepack install -g pnpm@10`, ou remettez le dossier `corepack` depuis la corbeille.

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
