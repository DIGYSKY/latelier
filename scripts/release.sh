#!/usr/bin/env bash
# Construit l’app, la signe, la notarise si possible, et produit build/LAtelier-<version>.dmg.
#
#   scripts/release.sh                              → .dmg signé avec le certificat auto-signé
#                                                     (scripts/make-signing-cert.sh), sinon ad hoc
#   SIGN_IDENTITY="Developer ID Application: Nom (TEAMID)" \
#   NOTARY_PROFILE="latelier" scripts/release.sh   → signé, notarisé, agrafé (distribuable)
#
# Préparer le profil de notarisation une fois :
#   xcrun notarytool store-credentials latelier --apple-id <e-mail> --team-id <TEAMID>
# BUNDLE_ID remplace l’identifiant « io.github.digysky.latelier » (pour un fork).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
APP="build/L’Atelier.app"
DMG="build/LAtelier-$VERSION.dmg"

scripts/build-app.sh

if [[ "${SIGN_IDENTITY:-}" != "Developer ID"* ]]; then
    echo "ℹ︎ Sans Developer ID, Gatekeeper demandera « Ouvrir quand même » au premier lancement" >&2
    echo "  (Réglages Système › Confidentialité et sécurité). Voir le README." >&2
fi

# Image disque : l’app et un raccourci vers /Applications.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "L’Atelier $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [[ "${SIGN_IDENTITY:-}" == "Developer ID"* ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    [[ -n "${SIGN_IDENTITY:-}" ]] || { echo "La notarisation demande SIGN_IDENTITY (Developer ID)." >&2; exit 1; }
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
else
    echo "ℹ︎ Pas de NOTARY_PROFILE : .dmg non notarisé." >&2
fi

# Empreinte publiée à côté du .dmg : la mise à jour intégrée la vérifie avant d’installer.
(cd build && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
cat "$DMG.sha256"
echo "$DMG"
