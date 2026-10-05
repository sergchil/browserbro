# BrowserBro

Open every link in the right browser **and profile** on macOS.

BrowserBro is a small menu bar app that becomes your default browser. When you click a link anywhere on your Mac:

- if one of your rules matches, the link opens right away in the browser and profile you chose;
- if not, a Liquid Glass picker opens **at your mouse pointer**: press `1`–`9` (or click) to choose.

Website: https://sergchil.github.io/browserbro/

## Features

- Rules by domain, host, path, URL text, wildcard, regex, the app you clicked in, or a held key. Combine with all / any / NOT. First match wins.
- Conflict warnings and a built-in tester that explains which rule wins and why.
- Profiles: Chrome, Brave, Edge, Vivaldi, Chromium (profile folders), Firefox, Zen, LibreWolf, Waterfox (profiles), Arc (via Spaces). Safari as a browser.
- Picker keys: `1`–`9`, arrows + `Return`, `Esc`, `⌥` = private window, `Tab` = "always open this site here", `⌘C` = copy link.
- Rules live in a readable file: `~/Library/Application Support/BrowserBro/rules.json`.
- Private: no network calls, no accounts, no analytics.

## Requirements

macOS 26 (Tahoe) or later, Apple Silicon.

## Install

BrowserBro is free. Pick one way:

**Homebrew** (no security prompt):

```bash
brew install --cask sergchil/tap/browserbro
```

Update later with `brew upgrade --cask browserbro`.

**One line in Terminal** (no security prompt; run it again to update):

```bash
curl -fsSL https://raw.githubusercontent.com/sergchil/browserbro/main/scripts/install.sh | bash
```

It downloads the latest release, checks its SHA-256, installs to `/Applications` (or `~/Applications`), removes the quarantine flag and opens the app.

**Download**: [BrowserBro.zip](https://github.com/sergchil/browserbro/releases/latest/download/BrowserBro.zip) (or [BrowserBro.dmg](https://github.com/sergchil/browserbro/releases/latest/download/BrowserBro.dmg)) from [Releases](https://github.com/sergchil/browserbro/releases/latest). Unzip it and drag BrowserBro to Applications. The first time you open it:

1. macOS says it cannot verify BrowserBro. Click **Done** (not "Move to Trash").
2. Open **System Settings → Privacy & Security**, scroll down to **Security**, and click **Open Anyway**. The button stays for about one hour.
3. Enter your Mac password, then click **Open**. macOS remembers your choice.

Right-click → Open no longer skips this check on recent macOS. Shortcut for Terminal users: `xattr -dr com.apple.quarantine /Applications/BrowserBro.app`.

Why the warning? BrowserBro is not notarized by Apple, because notarization costs $99 a year. The code is open: read it, or build it yourself.

After installing, open BrowserBro Settings and click **Set as Default Browser…**.

## Build from source

```bash
git clone https://github.com/sergchil/browserbro.git
cd browserbro
scripts/build-app.sh --install   # builds, ad-hoc signs, copies to /Applications
```

You need Xcode 26+ or the Command Line Tools with Swift 6.2+. No paid Apple Developer account is needed.

Run the tests:

```bash
swift test
```

## Releasing

Push a tag `vX.Y.Z`. The `Release` workflow (GitHub Actions, `macos-26` runner) runs the tests, builds the app with `scripts/make-dmg.sh` and publishes the ZIP, DMG and SHA-256 files to GitHub Releases. Then bump `version` and `sha256` in [sergchil/homebrew-tap](https://github.com/sergchil/homebrew-tap) `Casks/browserbro.rb`.

Local build of the release files: `VERSION=1.0.0 scripts/make-dmg.sh` (output in `build/`).

## Project layout

| Path | What |
|---|---|
| `Sources/RoutingCore` | Rule model, matching engine, conflict checks (pure Swift, fully tested) |
| `Sources/BrowserBro` | The app: link intake, browser catalog, launcher, picker, settings |
| `Sources/bro` | `bro test <url>` command-line rule tester |
| `site/` | Product page (GitHub Pages) |
| `PRD.md`, `DESIGN.md`, `ROADMAP.md`, `RESEARCH.md` | Product and design docs |

## License

MIT, see [LICENSE](LICENSE).
