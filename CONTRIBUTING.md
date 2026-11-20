# Contributing to L’Atelier

<sub>**English** · [Français](CONTRIBUTING_fr.md)</sub>

Thanks for your interest! Bug reports, ideas and pull requests are all welcome.

## Reporting a bug or suggesting an idea

The quickest way is from the app: **Settings › About › Report a Problem** (or **Help › Report a
Problem**). It opens a prefilled GitHub issue with the app and macOS versions; you review it before
posting. From the History, a failed action has a **Report This Problem** button that adds the error
output, with your home folder and account name hidden.

## Setting up

You only need Apple’s Command Line Tools (`xcode-select --install`), not Xcode.

```bash
git clone https://github.com/DIGYSKY/latelier.git
cd latelier
make run      # build and launch
make test     # unit and integration tests
make smoke    # open every screen of the real app (quits a running L’Atelier)
```

Without Xcode, SwiftUI’s `@State` macro is unavailable: use `@ViewState` (an alias defined in
`Sources/LAtelier/App/ViewState.swift`), and don’t use `#Preview`.

## Guidelines

- **Safety first.** Anything that deletes, modifies or runs a command goes through an `ActionPlan`
  shown in the preview, and is recorded in the history. Deletions go to the Trash by default.
  Remote commands are always built with `ShellQuote`.
- **Logic in `LAtelierCore`, with tests.** The app target (`LAtelier`) stays thin. A change to the
  core comes with Swift Testing tests in `Tests/LAtelierCoreTests`.
- **No third-party dependencies**, no telemetry, no network call beyond those listed in the README.
- **Both languages.** French is the source language: write user-visible text in French in the code
  (`Text("…")`, or `String(localized: "…")` for any other string), then run `make l10n`. It lists
  the sentences without an English translation; add them to `Support/Localization/en.json`.
  Don’t localize technical strings (commands, paths, identifiers), and pass PIDs, ports and codes as
  `String(value)` so they are not formatted like quantities (`4 821`).
- **Name**: always “L’Atelier”, with the typographic apostrophe `’` (U+2019).

## Pull requests

1. One topic per pull request, with a short description of the why.
2. `make test` passes; `make smoke` too if you touched the UI.
3. Add a line to `CHANGELOG.md` and `CHANGELOG_fr.md`.

By contributing, you agree that your contribution is released under the project’s
[GPL v3 license](LICENSE).
