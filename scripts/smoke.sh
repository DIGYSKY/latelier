#!/usr/bin/env bash
# Test de bout en bout : ouvre la vraie app sur chaque écran et vérifie qu'elle tient debout
# (pas de plantage, pas de rapport de crash). Aussi : Serveurs sans ~/.ssh/config, premier lancement.
#   scripts/smoke.sh            → tous les écrans, 6 s chacun
#   WAIT=10 scripts/smoke.sh
# Attention : quitte L’Atelier s'il est ouvert.
set -uo pipefail
cd "$(dirname "$0")/.."
APP="build/L’Atelier.app"
WAIT="${WAIT:-6}"
[[ -d "$APP" ]] || scripts/build-app.sh >/dev/null

# Les écrans : les « case » de l'énumération Page.
PAGES=$(awk '/^enum Page/,/^    var id/' Sources/LAtelier/Navigation/Navigation.swift | grep -E '^[[:space:]]+case ' | sed -E 's/^[[:space:]]+case //; s/,//g' | tr ' ' '\n' | grep -v '^$')
CRASHES="$HOME/Library/Logs/DiagnosticReports"
before=$(ls "$CRASHES" 2>/dev/null | grep -c '^LAtelier' || true)
failed=0

run() {
    local label=$1; shift
    pkill -x LAtelier 2>/dev/null; sleep 1
    open "$@" "$APP"
    sleep "$WAIT"
    if pgrep -x LAtelier >/dev/null; then
        printf '  ✓ %s\n' "$label"
    else
        printf '  ✗ %s : l’app s’est arrêtée\n' "$label"; failed=$((failed + 1))
    fi
}

echo "Écrans :"
for page in $PAGES; do run "$page" --env LATELIER_PAGE="$page"; done
echo "Cas particuliers :"
run "Serveurs sans ~/.ssh/config" --env LATELIER_PAGE=serveurs --env LATELIER_SSH_CONFIG=/nonexistent/config
run "Premier lancement" --env LATELIER_ONBOARDING=1
run "Réglages › À propos" --env LATELIER_PAGE=reglages --env LATELIER_SETTINGS=about
pkill -x LAtelier 2>/dev/null

after=$(ls "$CRASHES" 2>/dev/null | grep -c '^LAtelier' || true)
if [[ "$after" -gt "$before" ]]; then
    echo "✗ Nouveau rapport de plantage dans $CRASHES"; failed=$((failed + 1))
fi
[[ $failed -eq 0 ]] && echo "✓ Tout tient debout." || { echo "✗ $failed problème(s)."; exit 1; }
