#!/usr/bin/env bash
# Publie la version du fichier VERSION sur GitHub : tag vX.Y.Z, .dmg et son empreinte .sha256.
# L’app installée la verra à sa prochaine vérification (une fois par jour, ou Réglages › Rechercher).
#
#   scripts/publish-release.sh                 → notes générées depuis les commits
#   NOTES_FILE=notes.md scripts/publish-release.sh
# Nécessite gh (GitHub CLI) connecté, et un dépôt « origin » sur GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
TAG="v$VERSION"
DMG="build/LAtelier-$VERSION.dmg"

[[ -z "$(git status --porcelain)" ]] || { echo "Des modifications ne sont pas commitées." >&2; exit 1; }
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Le tag $TAG existe déjà : augmentez VERSION avant de publier." >&2
    exit 1
fi

scripts/release.sh

git tag -a "$TAG" -m "L’Atelier $VERSION"
git push origin "$TAG"

if [[ -n "${NOTES_FILE:-}" ]]; then
    gh release create "$TAG" "$DMG" "$DMG.sha256" --title "L’Atelier $VERSION" --notes-file "$NOTES_FILE"
else
    gh release create "$TAG" "$DMG" "$DMG.sha256" --title "L’Atelier $VERSION" --generate-notes
fi
echo "✓ Publiée : $(gh release view "$TAG" --json url --jq .url)"
