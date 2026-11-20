# Changelog

<sub>**English** · [Français](CHANGELOG_fr.md)</sub>

All notable changes to L’Atelier are listed here. Versions follow [Semantic Versioning](https://semver.org).

## [1.0.0-beta.3] — 2026-11-20

### Fixed
- **No more administrator password at launch.** Reading login items (`sfltool`, protected by macOS) happened during “Analyze everything at launch”, so macOS asked for the administrator password at every launch. Login items are now read only when you ask, from Performance › Login Items.

### Improved
- **Clearer updates.** The update preview shows the new and current versions with an “Install the Update” button, and ends with “L’Atelier x is installed” and **Relaunch Now** / **Later**. If you choose Later, a banner on the Home screen reminds you to relaunch.

## [1.0.0-beta.2] — 2026-11-20

### Fixed
- **Caches**: cleaning the Corepack cache (`~/.cache/node/corepack`) could break pnpm. Without it, Corepack downloads the latest pnpm (12), which the Corepack bundled with Node 22 cannot run. This cache is now “To check” and no longer selected by default.
- **Cleanup order**: tool commands (`pnpm store prune`…) now run before files are moved to the Trash, so a removed cache can no longer break a tool that still has to run.
- **Failure explanations**: a pnpm/yarn version that Corepack cannot run is recognized, with a “Go Back to pnpm 10…” fix; a missing tool file is no longer described as a missing project dependency.

> If pnpm stopped working after a cleanup with beta 1: run `corepack install -g pnpm@10`, or put the `corepack` folder back from the Trash.

## [1.0.0-beta.1] — 2026-11-20

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
