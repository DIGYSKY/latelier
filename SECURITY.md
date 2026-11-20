# Security policy

<sub>**English** · [Français](SECURITY_fr.md)</sub>

L’Atelier deletes files, runs commands, edits `~/.ssh/config`, acts on your servers and updates
itself. Security reports are taken seriously and handled first.

## Reporting a vulnerability

**Please do not open a public issue.** Use a
[private security advisory](https://github.com/DIGYSKY/latelier/security/advisories/new) on GitHub.

Include, if you can:
- the version (Settings › About › Copy Diagnostic Info),
- what an attacker can do, and under which conditions,
- steps to reproduce, or a proof of concept.

You will get an answer within a week. Once fixed, the advisory is published with the fix and
credits you, unless you prefer to stay anonymous.

## Supported versions

During the beta, only the **latest** `1.0.0-beta` release receives fixes. The built-in updater
delivers them to every user.

## What is in scope

- Deleting or modifying anything without a preview, or outside the user’s home folder.
- Command injection: local commands, remote SSH commands, file names on a server.
- The updater: installing an app that is not verified (checksum, signing certificate).
- Data sent over the network beyond what the README’s privacy table lists.
