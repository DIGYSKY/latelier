#!/usr/bin/env bash
# Construit l’app, la signe, la notarise si possible, et produit build/LAtelier-<version>.dmg.
#
#   scripts/release.sh                              → .dmg signé ad hoc (pour cette machine)
#   SIGN_IDENTITY="Developer ID Application: Nom (TEAMID)" \
#   NOTARY_PROFILE="latelier" scripts/release.sh   → signé, notarisé, agrafé (distribuable)
#
# Préparer le profil de notarisation une fois :
#   xcrun notarytool store-credentials latelier --apple-id <e-mail> --team-id <TEAMID>
# BUNDLE_ID remplace l’identifiant « local.latelier » (ex. com.exemple.latelier).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
APP="build/L’Atelier.app"
DMG="build/LAtelier-$VERSION.dmg"

scripts/build-app.sh

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    echo "⚠︎ Pas de SIGN_IDENTITY : signature ad hoc. Le .dmg s’ouvre sur ce Mac ;" >&2
    echo "  ailleurs, Gatekeeper le bloquera (clic droit › Ouvrir, ou un certificat Developer ID)." >&2
fi

# Image disque : l’app et un raccourci vers /Applications.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "L’Atelier $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
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

shasum -a 256 "$DMG"
echo "$DMG"
