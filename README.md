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
