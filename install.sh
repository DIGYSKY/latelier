#!/usr/bin/env bash
# Installe L’Atelier en le compilant sur ce Mac : aucun avertissement de Gatekeeper,
# puisque rien n’est téléchargé en binaire.
#
#   curl -fsSL https://raw.githubusercontent.com/DIGYSKY/latelier/main/install.sh | bash
#   ./install.sh            (depuis un clone : compile ce dossier)
#
# Variables : LATELIER_REPO (propriétaire/dépôt), LATELIER_SOURCE (dossier des sources),
#             LATELIER_REF (tag ou branche ; par défaut la dernière version publiée).
set -euo pipefail

REPO="${LATELIER_REPO:-DIGYSKY/latelier}"
APP_NAME="L’Atelier.app"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

bold "L’Atelier — installation depuis les sources"

# 1. Prérequis : macOS 26, outils de ligne de commande d’Apple (Swift, git).
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$MAJOR" -ge 26 ]] || fail "macOS 26 ou plus récent est nécessaire (vous avez $(sw_vers -productVersion))."
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
    info "Les outils de ligne de commande d’Apple (Swift, git) ne sont pas installés."
    info "Une fenêtre va proposer de les installer ; relancez ce script ensuite."
    xcode-select --install 2>/dev/null || true
    exit 1
fi

# 2. Sources : ce dossier s’il s’agit d’un clone, sinon ~/.latelier/source.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [[ -n "${LATELIER_SOURCE:-}" ]]; then
    SOURCE="$LATELIER_SOURCE"
elif [[ -n "$HERE" && -f "$HERE/Package.swift" && -d "$HERE/Sources/LAtelier" ]]; then
    SOURCE="$HERE"
else
    SOURCE="$HOME/.latelier/source"
fi

if [[ ! -d "$SOURCE/.git" ]]; then
    bold "Téléchargement des sources dans $SOURCE"
    mkdir -p "$(dirname "$SOURCE")"
    git clone --quiet "https://github.com/$REPO.git" "$SOURCE"
fi
cd "$SOURCE"

if [[ "$SOURCE" != "$HERE" ]]; then
    git fetch --quiet --tags --force origin
    REF="${LATELIER_REF:-$(git tag --list 'v*' --sort=-v:refname | sed -n 1p)}"
    REF="${REF:-origin/main}"
    bold "Version : $REF"
    git checkout --quiet --detach "$REF"
fi

# 3. Compilation (signée avec le certificat auto-signé s’il existe, sinon ad hoc).
bold "Compilation (quelques minutes la première fois)…"
# Seules les sources gérées par ce script sont mises à jour par l’app (git checkout du tag publié) ;
# un clone de travail n’est jamais touché : l’app se mettra alors à jour par l’image disque.
if [[ "$SOURCE" == "$HERE" ]]; then
    make app >/dev/null
else
    SOURCE_INSTALL=1 make app >/dev/null
fi
BUILT="$SOURCE/build/$APP_NAME"
[[ -d "$BUILT" ]] || fail "La compilation n’a pas produit $BUILT."

# 4. Installation dans /Applications (ou ~/Applications), l’ancienne version à la corbeille.
TARGET_DIR="/Applications"
[[ -w "$TARGET_DIR" ]] || TARGET_DIR="$HOME/Applications"
mkdir -p "$TARGET_DIR"
TARGET="$TARGET_DIR/$APP_NAME"
if [[ -e "$TARGET" ]]; then
    osascript -e 'tell application id "io.github.digysky.latelier" to quit' >/dev/null 2>&1 || true
    sleep 1
    TRASHED="$HOME/.Trash/L’Atelier $(date +%Y-%m-%d\ %H.%M.%S).app"
    mv "$TARGET" "$TRASHED"
    info "Ancienne version mise à la corbeille."
fi
ditto "$BUILT" "$TARGET"

bold "✓ L’Atelier est installé : $TARGET"
info "Les mises à jour se font ensuite depuis l’app (Réglages › Général), en recompilant la version publiée."
open "$TARGET"
