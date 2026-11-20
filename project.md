# L’Atelier

Boîte à outils macOS pour développeurs (anciennement « MachineCleaner »).

## Nom
- Nom affiché : **L’Atelier**, toujours avec le « L’ » et l'apostrophe typographique `’` (U+2019),
  jamais l'apostrophe droite `'` : titre de fenêtre, menu, Dock, Finder, volume du `.dmg`, site.
- Identifiants techniques, qui ne peuvent pas contenir d'apostrophe :
  - cible Xcode / exécutable : `LAtelier`
  - bundle ID : provisoire `local.latelier`, à remplacer par un domaine avant la signature Developer ID
  - fichier d'installation : `LAtelier-<version>.dmg` (volume monté nommé « L’Atelier »)

Application macOS native pour développeurs, distribuée en `.dmg` hors App Store, en style **Liquid Glass** (macOS 26).

## L'idée

Un seul outil pour garder sa machine de dev **propre, à jour et sûre** :

| Onglet | Rôle |
|---|---|
| **Accueil** | Vue d'ensemble : espace récupérable, dépôts à traiter, vulnérabilités, mises à jour, news critiques |
| **Stockage** | Le nettoyeur de disque d'origine (tous les sous-onglets actuels) |
| **Projets** | Dépôts git détectés sur la machine : gestion git, dépendances, veille et cybersécurité |
| **Paquets** | Tout ce qui est installé (brew, npm -g, pip…) : versions obsolètes, mises à jour |
| **Performance** | Gestionnaire des tâches : processeur, RAM, GPU, réseau, disque et processus en temps réel |
| **News** | Actualités des langages, outils et de la cybersécurité, filtrées selon ce qu'on utilise |
| **Historique** | Journal de toutes les actions (suppressions, mises à jour, commandes git) |

Principe directeur, qui vaut pour tous les onglets : **aucune action sans que l'utilisateur ait vu quoi, combien, et si c'est sans risque.**

## Navigation

```
Accueil
Stockage ▾
   Vue d’ensemble · Système
   Applications ▸ Nettoyage · Désinstalleur
   Docker · Développement · Caches · Explorateur · Sonar
Projets ▾
   Dépôts · Modifications · Commandes · Dépendances · Sécurité · Couverture
Paquets ▾
   Mises à jour · Inventaire · Runtimes · Services
Performance ▾
   Vue d’ensemble · Processus · Réseau · Démarrage · Enregistreur
News ▾
   Pour vous · Cybersécurité · Langages · Favoris · Sources
──────────
Historique
Réglages
```

Barre latérale en accordéon : seule la section courante est dépliée ; les sections repliées affichent
une pastille (failles, mises à jour, news non lues) ou une valeur (espace récupérable, % CPU).

---

## 1. Stockage

Le périmètre d'origine, inchangé. Point de départ concret (session de nettoyage du 19/11/2026) :
`~/Library` passé de 50 Go à 11 Go, plus ~9 Go d'artefacts de dev identifiés.

### Vue d’ensemble : répartition du disque entier
Barre segmentée et légende cliquable couvrant **tout** le volume, pas seulement ce qui est nettoyable :

| Catégorie | Contenu | Calcul |
|---|---|---|
| macOS | Volume système scellé (lecture seule) | taille du volume système APFS |
| Données système | Caches système, swap, instantanés Time Machine locaux, journaux | reste du volume Data non attribué |
| Applications | `/Applications`, `~/Applications` | somme des `.app` |
| Développeur | Xcode, simulateurs, Docker, artefacts, toolchains, caches de paquets | dossiers connus |
| Documents | `~/Documents`, `~/Desktop` (hors iCloud) | par dossier + types de fichiers |
| Images / Vidéos / Musique | Photothèque, `~/Pictures`, `~/Movies`, `~/Music`, podcasts | par type UTI (`UTType`) |
| Téléchargements | `~/Downloads` | dossier |
| Autres utilisateurs | autres comptes du Mac | lecture seule sans droits admin |
| Corbeille | `~/.Trash` | dossier |
| Autres | tout le reste (VM, bases locales…) | différence |

Chaque catégorie affiche sa taille, sa part du disque, ce qui est récupérable dedans, et renvoie vers l'écran adapté
(Système, Désinstalleur, Développement, Sonar, Explorateur).
Les tailles sont calculées sur l'espace réellement alloué (attention aux clones APFS et aux fichiers « purgeables »).

### Système
| Catégorie | Emplacement | Risque |
|---|---|---|
| Caches utilisateur | `~/Library/Caches` | Faible, recréés par les apps |
| Logs | `~/Library/Logs` | Faible |
| Corbeille | `~/.Trash` | Faible (définitif) |

### Applications › Nettoyage
- Restes d'apps déjà désinstallées dans `Application Support`, `Preferences`, `HTTPStorages`, `Containers`…
- Lien bundle ID ↔ nom lisible (ex. `com.todesktop.230313mzl4w4u92` → Cursor).
- Liens morts dans `/usr/local/bin` (droits admin), installations interrompues.

### Applications › Désinstalleur
- Liste des apps installées : taille totale (app + données), dernière utilisation, tri (plus lourdes, moins utilisées,
  inutilisées depuis 3 mois, nom), recherche.
- Détail par app : chaque emplacement (app, caches, données, réglages) avec sa taille, décochable un par un ;
  option « garder les réglages » pour une réinstallation plus tard.
- App ouverte : quittée proprement avant désinstallation. App installée via Homebrew : `brew uninstall --cask` puis nettoyage des restes.
- Passe par l'aperçu commun (corbeille par défaut).

### Docker
- Images, conteneurs, volumes, build cache (`docker system df -v`).
- **Sans risque** : images, conteneurs arrêtés, build cache, volumes anonymes ou de cache.
- **Données** : volumes de bases de données → jamais cochés par défaut, avertissement explicite.
- Installations interrompues (`com.docker.install/in_progress`) ; `Docker.raw` rend la place progressivement.

### Développement (artefacts)
| Type | Détection |
|---|---|
| `node_modules` | dossier |
| `target` | si `Cargo.toml` / `pom.xml` / `build.sbt` à côté |
| `venv` / `.venv` | si `pyvenv.cfg` présent |
| `__pycache__`, `.pytest_cache`, `.mypy_cache` | dossier |
| `.next`, `.nuxt`, `.turbo`, `.svelte-kit`, `.parcel-cache`, `.angular`, `.gradle` | dossier |

Exclure les artefacts internes aux outils (`~/.nvm`, `~/.espressif`…). Projets inactifs proposés en priorité.
→ Partage la détection de projets avec l'onglet **Projets**.

### Caches de paquets
npm (`npm cache clean --force`), pnpm (`pnpm store prune`), Go (`go clean -modcache`), Maven (`~/.m2`),
Xcode (`DerivedData`, simulateurs), `~/.cache` au cas par cas. Ne jamais toucher aux toolchains.

### Explorateur
Treemap des dossiers les plus lourds, avec une description en clair de chaque dossier connu.

### Sonar
Une manière ludique de trier ses fichiers personnels pour libérer de la place.
- **Radar** : chaque fichier (ou groupe de fichiers) est un point. Distance au centre = ancienneté de la dernière
  ouverture (`kMDItemLastUsedDate`), taille du point = poids, secteur = type (vidéos, images, audio, archives,
  installeurs / images disque, documents, machines virtuelles). Un balayage anime le radar et fait « pinger » les points.
- **Zones** : dossier personnel, Téléchargements, Documents, Vidéos… ; **filtres** : plus d'un an, plus d'1 Go,
  doublons, téléchargements oubliés.
- **Fiche** du fichier sélectionné : taille, dernière ouverture, **pourquoi il est proposé** (jamais ouvert, doublon
  de…, installeur déjà utilisé, app déjà installée, version obsolète…), Coup d’œil, Afficher dans le Finder.
- **Garder / Corbeille / Passer** : après chaque choix, le fichier suivant le plus lourd est sélectionné (tri rapide).
- Jauge « libéré / objectif », compteur de fichiers triés, liste de ce qui est parti à la corbeille, **annuler la dernière action**.
- Doublons détectés par taille puis empreinte (hash) ; les fichiers ouverts récemment restent près du centre et ne sont pas mis en avant.
- Tout part à la corbeille de macOS, jamais de suppression définitive depuis le Sonar.

---

## 2. Projets

### Détection
- Scan des dossiers racines configurables (`~/projects`, `~/work`, `~/Developer`… ; par défaut `~` avec profondeur limitée).
- Un projet = un dossier contenant `.git`. On ignore `node_modules`, `~/Library`, les dépôts internes aux outils (`~/.nvm`, `~/.cargo/registry`…).
- Détection des langages et de l'écosystème à partir des fichiers présents (`package.json`, `Cargo.toml`, `go.mod`, `pyproject.toml`…).
- Rafraîchissement en arrière-plan avec FSEvents.

Sous-pages : **Dépôts** (liste + détail d'un dépôt), **Modifications** (tout ce qui n'est pas commité, pas poussé
ou en retard, tous dépôts confondus, avec stash / pull / push / « pousser tout »), **Dépendances** (vue groupée par
bibliothèque : quels projets, quelles versions, alignement), **Sécurité** (failles par gravité, secrets, fin de vie,
hygiène), **Couverture** (voir plus bas).

### Vue liste (Dépôts)
Pour chaque dépôt : nom, chemin, langages, branche courante, état (propre / modifié / non poussé / en retard sur le distant / sans distant),
dernier commit, nombre de vulnérabilités, nombre de dépendances obsolètes, taille des artefacts (lien vers Stockage).

Filtres rapides : *modifiés non commités*, *commits non poussés*, *sans remote*, *inactifs*, *vulnérables*.

### Git
- Statut, diff des fichiers modifiés, staging, commit, stash.
- Branches : liste, changement, création, suppression des branches déjà fusionnées.
- `fetch` / `pull` / `push` avec ahead/behind ; fetch groupé de tous les dépôts.
- Historique (log graphique simple), tags.
- Via la CLI `git` (comportement identique au terminal, respecte la config et les clés SSH de l'utilisateur).
- Actions destructrices (reset, force push, suppression de branche non fusionnée) : confirmation explicite, jamais en lot.

### Dépendances
Lecture des manifestes et lockfiles :

| Écosystème | Fichiers |
|---|---|
| npm / pnpm / yarn | `package.json`, `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock` |
| Rust | `Cargo.toml`, `Cargo.lock` |
| Python | `pyproject.toml`, `poetry.lock`, `requirements*.txt`, `uv.lock` |
| Go | `go.mod`, `go.sum` |
| Java / Kotlin | `pom.xml`, `build.gradle(.kts)` |
| Swift | `Package.swift`, `Package.resolved` |
| Ruby / PHP | `Gemfile.lock`, `composer.lock` |

Pour chaque dépendance : version utilisée, dernière version, écart (patch / mineur / majeur), directe ou transitive, licence.

### Veille et cybersécurité
- **Vulnérabilités** : interrogation de [OSV.dev](https://osv.dev) (gratuit, couvre tous les écosystèmes ci-dessus, requêtes groupées),
  complétée par GitHub Advisory Database. Gravité CVSS, version corrigée, lien vers l'avis.
- **Obsolescence** : dernières versions depuis les registres (npm, crates.io, PyPI, proxy Go, Maven Central, RubyGems…).
- **Fin de vie** des runtimes (Node 18, Python 3.8…) via [endoflife.date](https://endoflife.date).
- **Secrets commités** : détection de motifs connus (clés AWS, tokens GitHub, `.env` suivi par git…).
- Proposer la mise à jour (commande de l'écosystème affichée avant exécution), jamais automatique.

**Confidentialité** : seuls des noms de paquets et des versions sortent de la machine, jamais de code ni de chemins.

### Ouvrir dans…
- **Ouvrir dans Claude** : ouvre le terminal choisi dans les réglages (Terminal, iTerm, Ghostty, Warp) dans le dossier
  du projet et lance `claude` (Claude Code en ligne de commande).
- **Avec contexte** : depuis une faille, une commande en échec ou une suggestion, « Corriger avec Claude » /
  « Demander à Claude » lance `claude "<consigne>"` pré-remplie (ex. « Mets à jour next vers 14.2.x et corrige ce qui casse »).
  La consigne est affichée avant l'ouverture.
- Aussi : Terminal, éditeur par défaut (VS Code, Cursor, Zed, Xcode…), Finder.

### Commandes
- **Détection** des commandes du projet : scripts `package.json`, cibles `Makefile`, `justfile`, `Taskfile.yml`,
  services `docker-compose.yml`, Cargo (`run`, `test`, `build`), Maven / Gradle, `pyproject.toml` (`[tool.*.scripts]`), Swift.
- Classées par usage : **Lancer**, **Tester**, **Construire**, **Qualité**, **Déployer** ; source affichée.
- Exécution dans le dossier du projet avec **sortie en direct**, arrêt possible, dernier résultat (succès / échec, durée).
- Commandes **épinglées** ; les commandes sensibles (déploiement, suppression, migrations) demandent une confirmation.
- **Suggestions** : commande manquante alors que l'outil est installé (lint avec ESLint présent, `test:coverage`,
  rapport JaCoCo configuré mais jamais lancé), wrapper à utiliser (`./mvnw`, `./gradlew`), port souvent occupé…
  Actions : ajouter au projet (modification du fichier affichée avant écriture), appliquer, demander à Claude, ignorer.
- Lien avec l'**Enregistreur** : une commande peut être enregistrée directement.

### Couverture de tests
- Lecture des rapports existants : `lcov.info`, Cobertura (`coverage.xml`), JaCoCo, `xccov` (Xcode), `cargo llvm-cov`.
- Sinon, lancement de la commande de tests avec couverture détectée selon l'écosystème
  (`npx vitest run --coverage`, `npx jest --coverage`, `pytest --cov`, `cargo llvm-cov`, `mvn verify jacoco:report`,
  `swift test --enable-code-coverage`), avec la commande affichée avant exécution et la sortie en direct.
- Par projet : lignes / branches / fonctions, tendance par rapport au run précédent, fichiers les moins couverts.
- Seuil configurable (80 % par défaut) : sous le seuil, le projet est signalé (Accueil, Dépôts).
- Historique des runs conservé localement pour tracer l'évolution.

---

## 3. Paquets (machine)

Sous-pages : **Mises à jour**, **Inventaire** (tout ce qui est installé, même à jour, par source, avec les paquets
jamais utilisés), **Runtimes**, **Services**.

Recense tout ce qui est installé globalement :

| Source | Lecture | Mise à jour |
|---|---|---|
| Homebrew (formules + casks) | `brew outdated --json=v2` | `brew upgrade <nom>` |
| npm / pnpm globaux | `npm outdated -g --json` | `npm i -g <nom>@latest` |
| pip / pipx / uv tools | `pipx list --json`, `pip list --outdated` | `pipx upgrade <nom>` |
| Cargo | `cargo install --list` + crates.io | `cargo install <nom>` |
| Go | binaires dans `~/go/bin` | `go install <module>@latest` |
| RubyGems | `gem outdated` | `gem update <nom>` |
| Runtimes | `rustup`, `nvm`, `pyenv`, Xcode CLT | commande dédiée |
| Mac App Store | `mas outdated` (si installé) | `mas upgrade` |

- Pour chaque paquet : version installée / disponible, type de mise à jour, vulnérabilités connues (OSV), fin de vie, lien vers le changelog.
- Mise à jour unitaire, par sélection ou par source, avec la commande affichée et la sortie en direct.
- Les mises à jour **majeures** ne sont jamais cochées par défaut.

### Runtimes
- Versions installées par langage (Node via nvm, Python via Homebrew / uv / pyenv, Rust via rustup, Java via SDKMAN!, Go, Swift).
- Version par défaut, projets qui utilisent chaque version (`.nvmrc`, `pyproject.toml`, `rust-toolchain`…), fin de vie.
- Actions : définir par défaut, installer la LTS, supprimer une version inutilisée (impossible si un projet l'utilise).

### Services
- `brew services` et agents de dev (postgres, redis, nginx, ollama…) : état, port, mémoire.
- Démarrer / arrêter / redémarrer, lancement au démarrage, derniers logs.

---

## 4. Performance (gestionnaire des tâches)

### Vue d'ensemble en temps réel
| Ressource | Ce qu'on affiche | Source |
|---|---|---|
| Processeur | Charge totale et par cœur (performance / efficacité), historique 60 s | `host_processor_info` |
| Mémoire | Utilisée, app, compressée, en cache, swap, **pression mémoire** | `host_statistics64`, `sysctl vm.swapusage` |
| GPU | Utilisation, mémoire GPU | IOKit (`IOAccelerator` → `PerformanceStatistics`) |
| Réseau | Débit montant / descendant, total de la session, interfaces actives | `getifaddrs` |
| Disque | Lecture / écriture par seconde, espace libre | IOKit (`IOBlockStorageDriver`) |
| Énergie | Batterie, état thermique | `ProcessInfo.thermalState`, IOKit |

Graphiques glissants, rafraîchis chaque seconde ; l'échantillonnage s'arrête quand la fenêtre est cachée.

### Processus
- Liste triable : nom, icône, PID, utilisateur, % CPU, mémoire, threads, débit réseau, ports ouverts.
- Regroupement par app (Chrome et ses processus d'aide) ou vue arborescente parent / enfants.
- Recherche, filtres : *mes processus*, *processus de dev* (node, python, java, docker, serveurs…), *gros consommateurs*.
- **Ports en écoute** : quel processus occupe le port 3000 / 5432 / 8080 (utile en dev).
- Actions : quitter, forcer à quitter (confirmation), afficher dans le Finder, ouvrir le dossier du projet si le processus en vient.
- Processus système et processus d'autres utilisateurs : lecture seule.
- Alertes optionnelles : processus qui consomme beaucoup de CPU depuis longtemps, fuite mémoire probable.

Lien avec les autres onglets : un processus qui bloque un nettoyage (règle 3) est affiché ici, et un serveur de dev est relié à son projet dans **Projets**.

Limite : la température et la consommation détaillées demandent `powermetrics` (droits admin) → option, désactivée par défaut.

### Réseau
- Débit, interface active, VPN.
- **Ports en écoute** avec portée : local uniquement (`127.0.0.1`) ou **exposé au réseau local** (`0.0.0.0`, signalé) ;
  action « libérer le port » (quitte le processus, avec confirmation).
- Trafic par processus et principales destinations.

### Démarrage
- Éléments de connexion, agents utilisateur (`~/Library/LaunchAgents`), agents et démons système (`/Library/…`, admin).
- Impact estimé, éditeur / signature, activer / désactiver.
- Agents **orphelins** (app supprimée) signalés et supprimables.

### Enregistreur de performances
- **Détection automatique** (mode par défaut) : L’Atelier surveille la liste des processus (sondage toutes les 1 à 2 s
  via `sysctl KERN_PROC`) et lit leur **dossier de travail** (`proc_pidinfo` / `PROC_PIDVNODEPATHINFO`).
  Un processus de dev (node, java, cargo, python, go, ruby, docker compose…) dont le dossier est dans un projet connu
  est rattaché à ce projet, avec sa ligne de commande et ses processus enfants (arbre parent / enfants).
- Politique réglable globalement et par projet : **enregistrer automatiquement**, **me demander** (bannière
  Enregistrer / Toujours pour ce projet / Ignorer), **désactivé** ; projets exclus possibles.
- Ignore les processus courts (moins de 5 s : git, lint, hooks) ; l'enregistrement s'arrête tout seul quand le
  processus se termine, et la session est rangée avec le projet et la commande exacte.
- Sondage léger et suspendu sur batterie si l'utilisateur le souhaite. Pas d'Endpoint Security (entitlement Apple
  difficile à obtenir hors App Store) : le sondage suffit pour des processus qui durent plusieurs secondes.
- **Manuel** toujours possible : lancer une commande du projet (depuis **Commandes**) ou s'attacher à un processus
  existant ; processus enfants inclus en option.
- Pendant l'enregistrement : CPU, mémoire, disque, réseau échantillonnés (250 ms à 1 s), courbes en direct, chronomètre.
- **Repères** : manuels (« ajouter un repère ») et automatiques (pics de CPU / mémoire détectés).
- Sessions sauvegardées par projet : durée, CPU moyen / max, mémoire max, E/S.
- **Comparaison** de deux sessions (ex. avant / après une optimisation) : écarts en % et en valeur.
- Export des sessions (JSON / CSV) pour les partager ou les suivre dans le temps.

---

## 5. News

- Agrégation de flux RSS / Atom et d'API publiques :
  - **Langages et outils** : blogs officiels Rust, Go, Python, Node.js, TypeScript, Swift, Kotlin, notes de version des outils installés…
  - **Cybersécurité** : CERT-FR, CISA KEV (vulnérabilités activement exploitées), avis GitHub, NVD.
  - **Général** (optionnel) : Hacker News, Lobsters.
- **Personnalisé automatiquement** : les sujets suivent les langages des projets et les paquets installés.
- **Alerte** quand une news ou un avis touche un paquet ou une dépendance présent sur la machine (lien direct vers le projet concerné).
- Lu / non lu, favoris, filtres par sujet ; sources ajoutables à la main.
- Notifications macOS seulement pour les alertes critiques (désactivables).
- Sous-pages : **Pour vous**, **Cybersécurité**, **Langages**, **Favoris**, **Sources** (gestion des flux, sujets suivis
  — déduits automatiquement des projets et paquets, ou ajoutés à la main —, état de chaque source).

---

## 6. Réglages
- **Général** : apparence, transparence, ouverture à la connexion, icône dans la barre des menus, accès complet au disque.
- **Stockage** : méthode de suppression par défaut, seuil d'inactivité des projets, dossiers exclus, Docker.
- **Projets** : dossiers racines, profondeur, fetch automatique, détection des secrets, seuil de couverture.
- **Vérifications** : fréquence des vérifications et des news, pause sur batterie, mises à jour majeures.
- **Notifications** : failles critiques, espace faible, news qui vous concernent, processus gourmand.
- **Confidentialité** : requêtes OSV / GitHub, télémétrie (désactivée par défaut), effacement de l'historique et du cache.

---

## Règles de sécurité (non négociables)
1. **Aperçu obligatoire** avant toute suppression, mise à jour ou commande git qui modifie quelque chose.
2. **Corbeille par défaut** (`FileManager.trashItem`), suppression définitive en option.
3. Ne rien toucher de ce qui est **en cours d'utilisation** (app ouverte, conteneur actif, dépôt avec opération git en cours).
4. Jamais de chemin système ; actions admin uniquement via demande d'autorisation explicite.
5. **Journal** de toutes les actions (quoi, quand, combien, sortie de commande) consultable dans l'Historique.
6. Erreurs visibles : une opération partielle est signalée, pas masquée.
7. Réseau : uniquement vers les registres, OSV et les sources de news ; aucun code ni chemin envoyé ; pas de télémétrie.

## Interface
- Style **Liquid Glass** : fenêtre translucide, barre latérale flottante, cartes en verre, boutons capsule.
- Badges de risque (vert / orange / rouge / protégé) communs à tous les onglets.
- Analyses rapides, parallèles, annulables, avec progression en direct.
- Mode clair / sombre.

## Choix technique

**Swift 6 + SwiftUI, cible macOS 26** (pour les matériaux Liquid Glass natifs), pas de sandbox, distribution directe.

- Scan parallèle avec `TaskGroup`, tailles via `URLResourceValues` (`totalFileAllocatedSize`).
- Surveillance des dossiers avec FSEvents.
- Outils externes (`git`, `docker`, `brew`, `npm`…) appelés via `Process`, avec sortie diffusée en direct.
- Réseau : `URLSession` + async/await ; cache local pour ne pas réinterroger les registres à chaque ouverture.
- Stockage local (projets, résultats, news, historique) : SwiftData ou SQLite (GRDB).
- Actions admin : `SMAppService` / helper privilégié, à défaut `AuthorizationServices`.
- Tâches de fond : rafraîchissement périodique des vulnérabilités et des news.

### Distribution
- Build Xcode → signature **Developer ID** → **notarisation** → `.dmg` (`create-dmg`).
- Premier lancement : accès complet au disque + choix des dossiers de projets.
- Mises à jour de l'app : Sparkle.

## Étapes
1. **Socle** : app SwiftUI, navigation, style Liquid Glass, historique, exécution de commandes avec aperçu.
2. **Stockage MVP** : Caches, Logs, artefacts de dev (scan, aperçu, corbeille).
3. **Projets** : détection des dépôts + état git (lecture seule), puis actions git et page Modifications.
4. **Paquets** : Homebrew et npm global d'abord, puis les autres sources ; Inventaire, Runtimes, Services.
5. **Dépendances et vulnérabilités** (OSV) pour Projets et Paquets ; page Sécurité.
6. **Performance** : métriques temps réel, processus, réseau / ports, démarrage.
7. **Commandes**, **Ouvrir dans Claude**, **Couverture de tests** et **Enregistreur de performances**.
8. **News** : flux, personnalisation, alertes croisées avec les paquets installés.
9. Reste du Stockage : répartition du disque, Docker, restes d'apps, désinstalleur, caches de paquets, explorateur, Sonar.
10. Réglages complets, signature, notarisation, `.dmg`.

## Développement

Swift Package (pas de projet Xcode à maintenir) ; Xcode peut ouvrir `Package.swift` directement.

| Commande | Effet |
|---|---|
| `make test` | tests du cœur (`LAtelierCore`) |
| `make app` | construit `build/L’Atelier.app` (release, signature ad hoc) |
| `make run` | construit puis ouvre l’app |
| `open --env LATELIER_PAGE=sonar "build/L’Atelier.app"` | ouvre directement un écran |

- `Sources/LAtelierCore` : commandes (`CommandRunner`, sans shell, sortie en direct, délai max, annulation), aperçus (`ActionPlan` → `PlanExecutor`), historique JSON dans `~/Library/Application Support/local.latelier/`, détection des outils.
- `Sources/LAtelier` : l’app SwiftUI (navigation, composants Liquid Glass, écrans).
- Toute action qui modifie passe par `model.preview(plan)` : feuille d’aperçu → exécution → Historique.
- Sans Xcode, la macro `@State` n’est pas disponible : on écrit `@ViewState` (alias du property wrapper).
- `LATELIER_AUTOPREVIEW=1` (avec `LATELIER_PAGE=dev`) ouvre l’aperçu dès la fin de l’analyse, sans rien exécuter : pratique pour les captures.
- Projets « en cours d’utilisation » : dossiers de travail des processus via `lsof -d cwd` (les shells sont ignorés). L’Enregistreur (étape 7) passera à `proc_pidinfo`.
- Performance : l’échantillonnage (1 s, `nettop` toutes les 5 s) ne tourne que si un écran Performance est affiché et la fenêtre visible ;
  `LATELIER_ALWAYS_SAMPLE=1` le force (captures avec la fenêtre sur un autre bureau). Hors binaires Apple, le noyau ne donne
  que les 32 bits bas des compteurs réseau : débits calculés modulo 2³², totaux lus avec `netstat -ib`.
- Ouvrir dans Claude / Terminal : un script `.command` (dans `~/Library/Caches/local.latelier/launch/`, 20 derniers gardés)
  fait `cd` dans le projet puis lance `claude '<consigne>'` ; Ghostty le reçoit via `-e`, Warp reçoit le dossier et la commande copiée.
- Commandes : arrêter une commande tue tout son arbre de processus (`npm run dev` → node → vite). Derniers résultats, épingles et
  suggestions ignorées dans `commands.json` ; historique de couverture dans `coverage-history.json` ; sessions de l’Enregistreur
  dans `recordings/` (Application Support). Les jetons passés en argument (`--token …`) sont masqués.
- Garde-fou de suppression (`SafetyGuard`) : uniquement dans le dossier personnel, jamais `~/Library`, `~/Documents`, `~/.ssh`, trousseaux…
- Signature Developer ID : `SIGN_IDENTITY="Developer ID Application: …" make app`.
