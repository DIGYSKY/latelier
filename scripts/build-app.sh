#!/usr/bin/env bash
# Construit « build/L’Atelier.app » à partir du Swift Package.
#   scripts/build-app.sh            → release, signature ad hoc
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
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
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    -e "s/local\.latelier/${BUNDLE_ID:-local.latelier}/" Support/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Developer ID : runtime renforcé + horodatage (obligatoires pour la notarisation). Sinon signature ad hoc.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --options runtime --timestamp=none --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "$APP"
