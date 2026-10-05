# AGENTS.md

Guide for AI coding agents (Claude Code, Hermes, Codex, Cursor) working on BrowserBro.
Humans: start with [README.md](README.md).

## What this is

BrowserBro is a macOS menu bar app. It becomes the default browser and sends each link
to the right browser **and profile**, using rules. No rule matches → a glass picker opens
at the pointer. Native Swift (AppKit + SwiftUI), no web view, no dependencies.

Product docs: [PRD.md](PRD.md) (requirements), [DESIGN.md](DESIGN.md) (UI, Liquid Glass),
[RESEARCH.md](RESEARCH.md) (other apps), [ROADMAP.md](ROADMAP.md) (phases).

## Layout

| Path | What |
|---|---|
| `Sources/RoutingCore/` | Pure logic: rule model, matching engine, conflicts, punycode, Arc sidebar parsing. No AppKit. All tests target this. |
| `Sources/BrowserBro/` | The app: link handling (`AppDelegate`), browser/profile discovery (`Catalog`), launching (`Launcher`), picker (`Floating`), Settings and rules UI, toast (`Pulse`), demo mode (`Demo`, `DemoTour`), `--self-test` (`SelfTest`). |
| `Sources/bro/` | `bro` CLI: `bro test <url>`, `bro check`, `bro corpus <file>` against a rules file. |
| `Tests/RoutingCoreTests/` | XCTest + JSON fixtures. |
| `scripts/` | `build-app.sh`, `make-dmg.sh`, `install.sh` (curl one-liner), `make-icon.swift`, `gen_corpus.py`. |
| `site/` | Static product page, deployed to GitHub Pages by `.github/workflows/pages.yml` on push to `main`. |
| `docs/media/` | README screenshots and GIFs (demo mode only). `docs/DEMO.md` explains demo mode. |

## Commands

```bash
swift test                                   # unit tests (must stay green)
scripts/build-app.sh                         # → build/BrowserBro.app (ad-hoc signed)
BROWSERBRO_SUPPORT_DIR=$(mktemp -d) \
  build/BrowserBro.app/Contents/MacOS/BrowserBro --self-test   # "Self-test PASSED (N checks)"
swift run bro test "https://example.com" --from com.tinyspeck.slackmacgap
VERSION=1.2.3 scripts/make-dmg.sh            # DMG + ZIP + .sha256 in build/
```

`scripts/build-app.sh --install` replaces `/Applications/BrowserBro.app`. Only run it when the
owner asks: it quits the running app.

## Environment switches

| Variable / arg | Effect |
|---|---|
| `BROWSERBRO_SUPPORT_DIR=<dir>` | Read/write rules and settings in `<dir>` instead of `~/Library/Application Support/BrowserBro`. **Always set it in tests and experiments.** |
| `BROWSERBRO_DEMO=1` | Fake browsers/profiles, no profile photos, links are logged, not opened. See `docs/DEMO.md`. |
| `--demo-url`, `--demo-pane`, `--demo-tour`, … | Demo capture helpers, see `docs/DEMO.md`. |
| `BROWSERBRO_INSTALL_DIR`, `BROWSERBRO_NO_OPEN` | `install.sh` testing: install elsewhere, don't launch. |

## Rules

- **Privacy.** Never read, print, or commit the owner's real `rules.json`, `settings.json`, browser
  profile names, or profile photos. Screenshots, GIFs and videos are made in demo mode only;
  look at every image before committing it.
- **Scope.** BrowserBro is rule-based link → browser/profile routing. No AI features, no cloud,
  no accounts, no telemetry, no paid services.
- **No paid Apple account.** The app is ad-hoc signed, not notarized. Don't add steps that need a
  Developer ID.
- **Keep logic in `RoutingCore`** and cover it with tests; the app layer stays thin.
- Match the existing style: Swift 6 language mode, `@Observable`, small files, no third-party packages.
- **Git.** Commit as `serg.chilingaryan@gmail.com` (check `git log -1 --format=%ae`). Never
  force-push `main`. No secrets, no absolute personal paths in committed files.
- Plain, short English in README, site and UI text. No sales copy.

## Releasing

Push a tag `vX.Y.Z` → `.github/workflows/release.yml` (macos-26 runner) runs tests, builds,
and creates the GitHub Release with DMG, ZIP, `.sha256` files and stable-named copies used by
`releases/latest/download/…`. Then bump `version` and `sha256` in the Homebrew cask
(`sergchil/homebrew-tap`, `Casks/browserbro.rb`) to the new ZIP. Details:
`.hermes/skills/browserbro-release/SKILL.md`.
