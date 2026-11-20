#!/usr/bin/env python3
"""Traductions : liste les phrases de l'app sans traduction anglaise.

Le français est la langue des sources : chaque texte visible est écrit en français dans le code
(Text("…"), String(localized: "…")). Le compilateur extrait ces phrases avec leurs paramètres
(%@, %lld…) ; ce script les compare à Support/Localization/en.json.

  scripts/l10n.py            → phrases sans traduction (et traductions devenues inutiles)
  scripts/l10n.py --json     → les phrases manquantes, prêtes à compléter dans en.json
"""
import glob
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, ".build", "l10n")
# Clés techniques que le compilateur voit mais qui ne s'affichent pas (formats de date, clés plist…).
TECHNICAL = ("EEE", "dd MMM", "Library/", "ssh ", "sudo ", "exec ", "cd %@", "if [", "kill -", "#", "docker ", "journalctl ")


def extract():
    subprocess.run(["swift", "build", "--build-path", BUILD, "-Xswiftc", "-emit-localized-strings",
                    "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", BUILD],
                   cwd=ROOT, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    keys = {}
    for path in glob.glob(os.path.join(BUILD, "**", "*.stringsdata"), recursive=True):
        data = json.load(open(path))
        for entry in data["tables"].get("Localizable", []):
            keys.setdefault(entry["key"], f'{data["source"].split("/Sources/")[-1]}:{entry["location"]["startingLine"]}')
    return keys


def main():
    keys = extract()
    english = json.load(open(os.path.join(ROOT, "Support", "Localization", "en.json")))
    french_words = lambda k: any(c in k for c in "éèêàçùâîôû’«") or " " in k.strip()
    missing = {k: v for k, v in keys.items() if k not in english and french_words(k) and not k.startswith(TECHNICAL)}
    unused = [k for k in english if k not in keys]
    if "--json" in sys.argv:
        print(json.dumps({k: "" for k in sorted(missing)}, ensure_ascii=False, indent=1))
        return
    print(f"{len(keys)} phrases · {len(english)} traduites en anglais · {len(missing)} à traduire · {len(unused)} inutilisées")
    for key, where in sorted(missing.items(), key=lambda kv: kv[1]):
        print(f"  {where}\t{key!r}")
    if unused:
        print("Traductions sans phrase correspondante (à retirer de en.json) :")
        for key in unused:
            print(f"  {key!r}")
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()
