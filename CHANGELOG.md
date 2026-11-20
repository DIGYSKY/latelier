# Changelog

<sub>**English** · [Français](CHANGELOG_fr.md)</sub>

All notable changes to L’Atelier are listed here. Versions follow [Semantic Versioning](https://semver.org).

## [1.0.0-beta.1] — unreleased

First public beta.

### Storage
- Whole-disk overview, with a detailed breakdown of “Other”.
- Development artifacts, package caches (cleared with each tool’s own command), Docker, app leftovers, uninstaller.
- Sonar (largest files and duplicates) and a folder-by-folder explorer.

### Projects
- Every git repository on the Mac, sorted by activity, with a page per repository: git, commands, dependencies, vulnerabilities, test coverage.
- The Projects badge counts **active projects with a critical vulnerability**.

### Servers
- SSH connections from `~/.ssh/config`: add, edit, duplicate, delete, without losing anything else in the file (comments, `Host *`, `Match`, `Include`, symlinked config).
- One-click terminal, remote file browser with built-in editor, server-side trash.
- Agentless monitor: CPU, memory, disks, network, processes, systemd services, Docker containers, ports; stop a process, restart a service or a container (with a preview; `sudo` happens in your terminal).

### Packages, Performance, News
- Package inventory and updates, runtimes, Homebrew services.
- Live monitor, processes, network, login items, dev-process recorder.
- News for your languages and security advisories matched against what is installed.

### Everywhere
- Guided first launch, English and French, menu bar extra, history of every action.
- Report a problem from the app (a prefilled GitHub issue, personal paths hidden).
- Updates from GitHub releases: checksum and signature verified, the current version is restored if anything fails.
- Settings › About: license, data stored on the Mac, clean uninstall.
