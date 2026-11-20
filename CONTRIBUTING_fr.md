# Contribuer à L’Atelier

<sub>[English](CONTRIBUTING.md) · **Français**</sub>

Merci de votre intérêt ! Signalements de bugs, idées et pull requests sont les bienvenus.

## Signaler un bug ou proposer une idée

Le plus simple est depuis l’app : **Réglages › À propos › Signaler un problème** (ou **Aide ›
Signaler un problème**). Une issue GitHub s’ouvre, pré-remplie avec les versions de l’app et de
macOS ; vous la relisez avant de publier. Dans l’Historique, une action en échec a un bouton
**Signaler ce problème** qui ajoute la sortie de l’erreur, avec votre dossier personnel et votre
nom de compte masqués.

## Mise en place

Il suffit des outils de ligne de commande d’Apple (`xcode-select --install`), pas de Xcode.

```bash
git clone https://github.com/DIGYSKY/latelier.git
cd latelier
make run      # compiler et lancer
make test     # tests unitaires et d’intégration
make smoke    # ouvrir chaque écran de la vraie app (quitte L’Atelier s’il est ouvert)
```

Sans Xcode, la macro `@State` de SwiftUI n’est pas disponible : utilisez `@ViewState` (un alias
défini dans `Sources/LAtelier/App/ViewState.swift`), et pas de `#Preview`.

## Principes

- **La sécurité d’abord.** Tout ce qui supprime, modifie ou lance une commande passe par un
  `ActionPlan` montré dans l’aperçu, et est noté dans l’historique. Les suppressions vont à la
  corbeille par défaut. Les commandes distantes sont toujours construites avec `ShellQuote`.
- **La logique dans `LAtelierCore`, avec ses tests.** La cible de l’app (`LAtelier`) reste fine.
  Un changement du cœur s’accompagne de tests Swift Testing dans `Tests/LAtelierCoreTests`.
- **Aucune dépendance externe**, aucune télémétrie, aucun appel réseau en dehors de ceux listés dans le README.
- **Les deux langues.** Le français est la langue des sources : écrivez les textes visibles en
  français dans le code (`Text("…")`, ou `String(localized: "…")` pour toute autre chaîne), puis lancez
  `make l10n`. Il liste les phrases sans traduction anglaise : ajoutez-les à `Support/Localization/en.json`.
  Ne traduisez pas les chaînes techniques (commandes, chemins, identifiants), et passez les PID, ports
  et codes en `String(valeur)` pour qu’ils ne soient pas formatés comme des quantités (`4 821`).
- **Le nom** : toujours « L’Atelier », avec l’apostrophe typographique `’` (U+2019).

## Pull requests

1. Un sujet par pull request, avec une courte explication du pourquoi.
2. `make test` passe ; `make smoke` aussi si vous avez touché à l’interface.
3. Ajoutez une ligne à `CHANGELOG.md` et `CHANGELOG_fr.md`.

En contribuant, vous acceptez que votre contribution soit publiée sous la
[licence GPL v3](LICENSE) du projet.
