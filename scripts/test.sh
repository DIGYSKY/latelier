#!/usr/bin/env bash
# Avec les seules Command Line Tools, la première compilation après une modification
# des tests échoue parfois (« plugin for module 'TestingMacros' not found »), puis passe.
# On relance une fois dans ce cas précis.
set -uo pipefail
cd "$(dirname "$0")/.."
LOG="$(mktemp)"
swift test "$@" 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
if [ "$STATUS" -ne 0 ] && grep -q "plugin for module 'TestingMacros' not found" "$LOG"; then
  echo "↻ Relance (plugin de macros de test non trouvé au premier essai)"
  swift test "$@"
  STATUS=$?
fi
rm -f "$LOG"
exit "$STATUS"
