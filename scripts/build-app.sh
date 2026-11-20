#!/usr/bin/env bash
# Construit « build/L’Atelier.app » à partir du Swift Package.
#   scripts/build-app.sh            → release ; signé avec « L’Atelier Self-Signed » s'il est dans
#                                     le trousseau (scripts/make-signing-cert.sh), sinon ad hoc
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#   SIGN_IDENTITY=- scripts/build-app.sh   → forcer la signature ad hoc
# Info.plist : LAtelierRepository (dépôt GitHub des mises à jour, depuis GITHUB_REPO ou le remote
# « origin ») et LAtelierSourcePath quand l'app est installée depuis les sources (install.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
VERSION="$(cat VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
APP="build/L’Atelier.app"

swift build -c "$CONFIG" --product LAtelier
BIN="$(swift build -c "$CONFIG" --show-bin-path)/LAtelier"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LAtelier"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Langues : le français est la langue des sources (les clés) ; les autres viennent de Support/Localization/<langue>.json.
mkdir -p "$APP/Contents/Resources/fr.lproj"
printf '{}' | plutil -convert binary1 -o "$APP/Contents/Resources/fr.lproj/Localizable.strings" -
for json in Support/Localization/*.json; do
    lang="$(basename "$json" .json)"
    mkdir -p "$APP/Contents/Resources/$lang.lproj"
    plutil -convert binary1 -o "$APP/Contents/Resources/$lang.lproj/Localizable.strings" "$json"
done
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    -e "s/io\.github\.digysky\.latelier/${BUNDLE_ID:-io.github.digysky.latelier}/" Support/Info.plist > "$APP/Contents/Info.plist"

# Dépôt GitHub d'où viennent les mises à jour : GITHUB_REPO=propriétaire/nom, sinon le remote origin.
REPO="${GITHUB_REPO:-}"
if [[ -z "$REPO" ]]; then
    REMOTE="$(git remote get-url origin 2>/dev/null || true)"
    REPO="$(printf '%s' "$REMOTE" | sed -nE 's#.*github\.com[:/]([^/]+/[^/]+)$#\1#p' | sed 's/\.git$//')"
fi
# Dépôt officiel par défaut (un fork le remplace avec GITHUB_REPO ou son propre remote).
REPO="${REPO:-DIGYSKY/latelier}"
[[ -n "$REPO" ]] && plutil -insert LAtelierRepository -string "$REPO" "$APP/Contents/Info.plist"
[[ -n "${SOURCE_INSTALL:-}" ]] && plutil -insert LAtelierSourcePath -string "$(pwd)" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Identité : Developer ID (runtime renforcé + horodatage, pour la notarisation), certificat auto-signé
# (identité stable : macOS garde les autorisations d'une version à l'autre), ou ad hoc.
SELF_SIGNED="L’Atelier Self-Signed"
if [[ -z "${SIGN_IDENTITY:-}" ]] && security find-certificate -c "$SELF_SIGNED" >/dev/null 2>&1; then
    # codesign ne retrouve pas un nom avec « ’ » : on le désigne par son empreinte SHA-1.
    SIGN_IDENTITY="$(security find-certificate -c "$SELF_SIGNED" -Z | awk '/SHA-1/ { print $NF; exit }')"
fi
case "${SIGN_IDENTITY:--}" in
    -) codesign --force --options runtime --timestamp=none --sign - "$APP" ;;
    "Developer ID"*) codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP" ;;
    *) codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP" ;;
esac
codesign --verify --strict "$APP"
echo "$APP"
