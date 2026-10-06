# Demo mode

Demo mode is for screenshots and screen recordings. It never shows real browser
profiles: no real profile names, no profile pictures.

## Environment

| Variable | What it does |
| --- | --- |
| `BROWSERBRO_DEMO=1` | Turns demo mode on. |
| `BROWSERBRO_SUPPORT_DIR=<dir>` | Rules and settings are read from and written to `<dir>`. Use an empty temp folder. Without it, demo mode uses `$TMPDIR/BrowserBro-demo`. The real files in `~/Library/Application Support/BrowserBro` are never touched in demo mode. |
| `BROWSERBRO_FORCE_LEGACY_UI=1` | Shows the macOS 14–15 look (materials instead of Liquid Glass) on macOS 26. Works with or without demo mode. |

What demo mode does:

- The picker and Settings show a fixed, made-up list, in this order:
  Safari; Chrome · Work; Chrome · Personal; Firefox · Side project; Arc · Work; Brave.
  No real profile is read.
- Icons are the real installed app icons. A browser that is not installed gets the
  generic app icon.
- Profiles get a monogram badge with a muted tint. Profile pictures are never loaded.
- Links are recorded, never opened. Each launch prints one line to stdout (and the
  unified log), for example:
  `Demo: would open https://jira.acme.com/x in Google Chrome · Work`
- When the rules file is empty, three demo rules are added:
  1. Work tools: `*.acme.com` or `linear.app` → Chrome · Work
  2. Slack links: links clicked in Slack → Arc · Work
  3. Videos: `youtube.com` → Safari

## Launch arguments (demo mode only)

| Argument | What it does |
| --- | --- |
| `--demo-url <url>` | Opens Settings → Tester with this link filled in. The result and trace show at once. |
| `--demo-pane <pane>` | Opens Settings on a pane: `general`, `browsers`, `rules`, `tester`, `about`. |
| `--demo-rule <n>` | Opens Settings → Rules with the editor of rule n (1-based) open. |
| `--demo-pick <url>` | Routes this link at launch, like a click in another app. With no matching rule the picker opens at the pointer; with a matching rule the launch is printed. |
| `--demo-point <x>,<y>` | With `--demo-pick`: first moves the pointer to this point (points, top-left origin of the main display), so the picker opens there. |
| `--demo-source <bundle id>` | With `--demo-pick`: the app the link came from, e.g. `com.tinyspeck.slackmacgap` to hit the Slack rule. |
| `--demo-presets <ids>` | Starts with no rules and opens the preset sheet on Rules, with these packs ticked, e.g. `work-apps,work-tools,meetings,code,media`. `-` = none ticked. |
| `--demo-appearance <light\|dark>` | Forces the light or dark look for this run. |
| `--demo-tour <dir>` | Scripted tour for README and site media. See the comment at the top of `Sources/BrowserBro/DemoTour.swift`. |

## Commands

Build first: `swift build`. Each command uses a fresh empty support folder.

```sh
# Tester with the winning rule and trace
BROWSERBRO_DEMO=1 BROWSERBRO_SUPPORT_DIR=$(mktemp -d) .build/debug/BrowserBro --demo-url https://jira.acme.com/x

# Browsers & Profiles pane (the fake list)
BROWSERBRO_DEMO=1 BROWSERBRO_SUPPORT_DIR=$(mktemp -d) .build/debug/BrowserBro --demo-pane browsers

# Rules pane, editor of rule 2 open
BROWSERBRO_DEMO=1 BROWSERBRO_SUPPORT_DIR=$(mktemp -d) .build/debug/BrowserBro --demo-rule 2

# Preset sheet (first-run look), dark
BROWSERBRO_DEMO=1 BROWSERBRO_SUPPORT_DIR=$(mktemp -d) .build/debug/BrowserBro \
  --demo-presets work-apps,work-tools,meetings,code,media --demo-appearance dark

# Picker at screen point (600, 400); no rule matches this link
BROWSERBRO_DEMO=1 BROWSERBRO_SUPPORT_DIR=$(mktemp -d) .build/debug/BrowserBro \
  --demo-pick https://docs.example.org/q4-plan --demo-point 600,400
```

The settings window and the picker show about 0.3 s after launch. A capture script
should wait about 2 s before taking the shot, and quit the app (kill the process)
before the next command.
