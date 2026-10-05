# Design: BrowserBro

Part A is the UI: a Liquid Glass interface that opens at the mouse pointer. Its look (not its placement) is inspired by OmniNotch. Part B is the system design (architecture).
Related: `PRD.md` (requirements by ID), `RESEARCH.md`, `ROADMAP.md`.

---

# Part A: UI design

## A1. Inspiration: style only

OmniNotch ([omninotch.app](https://omninotch.app)) is a paid, closed-source Mac utility. We borrow its **style**, not its placement, code or assets (viewed 2026-10-05).

What we take:

| Trait | How BrowserBro uses it |
|---|---|
| Springy, elastic motion | The picker grows out of the pointer with a spring and shrinks back into it. |
| Calm, mostly monochrome content | Text in system primary / secondary colors. The only color comes from browser icons and profile badges. |
| Soft "selected = highlight" in a row of icons | The selected tile is a tinted Liquid Glass "lens" that morphs between tiles. |
| Pill chips | The "Always open here" toggle and key hints are glass capsules. |

What we do **not** take: the placement. BrowserBro never draws at the top of the screen. The picker opens **next to the mouse pointer**, where the user just clicked the link. Their eyes and hand are already there.

**Our twist: Liquid Glass everywhere.** The whole picker is one floating Liquid Glass card. Tiles, the lens and chips are glass too.

## A2. Design principles

1. **One glance, one key.** The user should read the host and press a number within a second.
2. **Born at the pointer.** Every transient surface grows out of the mouse pointer and shrinks back into it.
3. **Glass, quiet content.** The card and everything you touch are glass; the content stays monochrome.
4. **No raw colors.** Use system semantic colors and materials only (`.primary`, `.secondary`, `.tint`, `Glass.regular`). No hex values in code.
5. **Respect the system.** Reduce Transparency, Reduce Motion and Increase Contrast each have a defined look (§A8).

## A3. Surfaces

| Surface | When it appears | Life span |
|---|---|---|
| **Drop** (picker) | No rule matched, or override key held. Opens at the mouse pointer. | Until a choice, `Esc` or a click outside. |
| **Pulse** (routed toast) | A rule routed the link. Small capsule just below-right of the pointer. | ~1.6 s, longer while hovered. |
| **Menu bar extra** | Always (can be hidden). | Opened by the user. |
| **Settings window** | Opened from the menu bar or by launching the app again. | Normal window. |

## A4. The Drop (picker)

### Layout (notch display, 5 targets)

```text
              ┌──────── hardware notch ────────┐
╭─────────────┤                                ├─────────────╮   ← top edge of screen
│ (ears: concave corners blend into menu bar)                │
│  🌐 linear.app                                 from  Slack  │   ← header
│     https://linear.app/acme/issue/ABC-…/…            │
│                                                            │
│  ╭────────╮ ╭────────╮ ╭────────╮ ╭────────╮ ╭────────╮    │
│  │ Chrome │ │ Chrome │ │ Safari │ │Firefox │ │  Zen   │    │   ← target tiles (Liquid Glass)
│  │  Work  │ │Personal│ │        │ │  Dev   │ │        │    │
│  │   1    │ │   2    │ │   3    │ │   4    │ │   5    │    │   ← key hints
│  ╰────────╯ ╰────────╯ ╰────────╯ ╰────────╯ ╰────────╯    │
│                                                            │
│  ( ◯ Always open linear.app here   ⇥ )      ⌥ private  esc │   ← footer chips
╰────────────────────────────────────────────────────────────╯
```

### Geometry

- **Width:** content-sized. Tile 88 × 92 pt, gap 10 pt, side padding 20 pt. 5 tiles ≈ 520 pt. Min 360 pt, max 720 pt. More than 7 targets → second row (max 2 rows; extra targets scroll horizontally).
- **Height:** header 52 + tiles 92 + footer 40 + padding ≈ 216 pt.
- **Top:** flush with the top of the screen. The top band (the height of the menu bar) stays black so the notch blends in.
- **Ears:** the two top corners curve **outward** (concave, radius 10 pt) into the menu bar, like OmniNotch. This is drawn with a custom `Shape`.
- **Bottom corners:** radius 30 pt, continuous (`.continuous` style).
- **Notch size is never hard-coded.** Read it at runtime from `NSScreen.safeAreaInsets.top`, `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`. Recompute on `NSApplication.didChangeScreenParametersNotification`.

### Material and color

| Element | Material | Notes |
|---|---|---|
| Shell on a notch display | Solid black (`Color.black`), shadow radius 24, y 8, opacity 0.35 | Black is the one allowed fixed color: it must match the hardware notch. |
| Shell on a display without a notch | `.glassEffect(.regular, in: .rect(cornerRadius: 30))` | Floating glass panel hanging from the top center. |
| Target tile | `.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))` | Reacts to hover and press like system glass buttons. |
| Selected tile ("lens") | `.glassEffect(.regular.tint(<profile color>).interactive(), ...)` + `glassEffectID` | The lens **morphs** from tile to tile as you press arrows. |
| Chips | `.glassEffect(.regular, in: .capsule)` | Toggle chip gets a tint when on. |
| Text | `.primary` / `.secondary` | On the black shell, the system resolves these to light colors via a forced dark color scheme on the panel. |

All tiles and the lens live inside one `GlassEffectContainer(spacing: 12)`, so glass shapes blend and morph instead of rendering as separate layers (Apple: "Applying Liquid Glass to custom views").

**Profile color.** Chromium profiles may store an avatar or theme color in `Local State`. If present, it tints the lens and the small avatar badge. If not, we use the system accent color. The tint stays subtle (glass tint, not a fill).

### Tile anatomy

```text
╭──────────────╮
│   [icon]●    │  ← browser app icon 40 pt; ● profile badge 16 pt (avatar image or monogram)
│   Chrome     │  ← 12 pt semibold, 1 line
│   Work       │  ← 11 pt regular, .secondary, 1 line, truncates tail
│     1        │  ← key hint in a tiny capsule, 10 pt monospaced digits
╰──────────────╯
```

Private-capable tiles show a small mask glyph (`SF Symbol: theatermasks`) when `⌥` is held, and the lens tint turns to `.purple` semantic tint.

### Typography (SF Pro, system)

| Role | Size / weight | Color |
|---|---|---|
| Host | 15 pt semibold | `.primary` |
| Full URL | 11 pt regular, middle truncation | `.secondary` |
| "from Slack" | 11 pt regular + 14 pt app icon | `.secondary` |
| Tile title | 12 pt semibold | `.primary` |
| Tile subtitle | 11 pt regular | `.secondary` |
| Key hints | 10 pt medium, monospaced digits | `.secondary` |

The host shows a generic `globe` SF Symbol. We never fetch a favicon (PRD N-3).

### Motion

| Moment | Animation |
|---|---|
| Open | Shell morphs from the notch rectangle to the full panel: `.spring(response: 0.38, dampingFraction: 0.78)`. Content fades in with a 60 ms delay and a 6 pt downward slide. |
| Arrow keys | Lens moves to the next tile with `.spring(response: 0.28, dampingFraction: 0.82)`; glass morph handles the shape change. |
| Choose | Chosen tile scales to 1.06 for 90 ms, then the panel collapses back into the notch (`response 0.32, damping 0.9`). The app icon rides up into the notch and fades. |
| Cancel (`Esc` or click outside) | Collapse with no tile highlight. |
| Queue ("1 of 3") | Header content cross-fades to the next link; the shell stays open. |

### Interaction

| Input | Action |
|---|---|
| `1`–`9` | Open in that target. |
| `←` `→` `↑` `↓` | Move the lens. |
| `Return` | Open in the target under the lens. |
| `⌥` + choice | Private window (if supported; otherwise the key does nothing and the tile shows no mask). |
| `Tab` | Toggle "Always open \<domain\> here". |
| `Esc` / click outside | Cancel. The link is not opened. |
| Hover a tile | Lens follows the pointer. |

The panel is a non-activating `NSPanel` (it takes key input without stealing the app focus forever), so after the choice, focus goes straight to the browser.

## A5. The Pulse (routed by a rule)

```text
╭──────────┤   notch   ├──────────╮
│ [Chrome●]              Work  ›  │    ← notch widens ~110 pt on each side, same height as the notch
╰─────────────────────────────────╯
```

- Left ear: target app icon with profile badge. Right ear: profile or browser name and a chevron.
- Shows for 1.4 s; stays while hovered; click → opens the Drop for the same link ("open elsewhere"). The original tab has already opened; the Drop only opens it a second time in the new target.
- Spring: `response 0.34, damping 0.8`. With Reduce Motion: fade only.
- On a display without a notch, the pulse is a small glass capsule at the top center, right under the menu bar.
- Can be turned off in Settings → General.

## A6. Menu bar extra

`MenuBarExtra` with `.window` style, so the content uses system Liquid Glass automatically on macOS 26.

```text
╭───────────────────────────────────╮
│ BrowserBro          ● Default ✓   │   ← status: is BrowserBro the default browser?
│───────────────────────────────────│
│ Recent                             │
│  linear.app → Chrome · Work        │   ← rule name on hover
│  youtube.com → Safari  (picker)    │
│  github.com → Firefox · Dev        │
│───────────────────────────────────│
│ When no rule matches:  [Picker ▾]  │
│ Open Rules…                ⌘,      │
│ Test a link…                       │
│ Quit                       ⌘Q      │
╰───────────────────────────────────╯
```

Menu bar icon: a custom template glyph (a small arrow splitting into two). Template images adapt to light and dark menu bars.

## A7. Settings window

`NavigationSplitView`. On macOS 26 the sidebar gets Liquid Glass from the system; we add no custom material to it.

| Sidebar item | Content |
|---|---|
| **General** | Default-browser status + button; fallback (picker / default target); override modifier; pulse on/off; launch at login; display mode (auto / always top-center). |
| **Browsers & Profiles** | List of targets grouped by browser; show/hide toggle; drag to reorder; custom key (1–9); custom label. Broken targets shown with a warning. |
| **Rules** | Ordered list with enable toggles, drag handles and conflict badges. Detail pane = rule editor. |
| **Tester** | URL field, sender-app picker, modifier toggles → result card and trace. |
| **About** | Version, license, link to the repo, "rules file: Reveal in Finder". |

### Rule editor (sentence style)

```text
Name  [ Work tools                         ]

When  [ any ▾ ]  of these match:
   [ Domain        ▾ ] [ linear.app          ]   [NOT]  ⊖
   [ Domain        ▾ ] [ slack.com           ]   [NOT]  ⊖
   [ Source app    ▾ ] [ 🟪 Slack             ]   [NOT]  ⊖
   ⊕ Add condition

Open in   [ 🟡 Chrome · Work ▾ ]
          ☐ Private window   ☐ Open in background

⚠ This rule is fully covered by rule 2 "All Slack links" and will never run.   [Show rule 2]
```

- Conditions use native pop-up buttons; "NOT" is a small toggle chip.
- The source-app field opens a searchable list of installed apps (icon, name, bundle ID).
- The warning banner is a glass card with `.tint(.orange)`; errors (bad regex) use `.tint(.red)`.
- Live mini-tester under the editor: "Try a URL" field that shows ✓ / ✗ for this rule only.

### Tester result

```text
https://docs.google.com/document/d/…   from Mail   ⌥ none

Winner:  Rule 7 "Google"  → Chrome · Personal

Trace
 1 Work tools          ✗  domain linear.app ≠ docs.google.com
 2 All Slack links     ✗  source app com.apple.mail ≠ com.tinyspeck.slackmacgap
 4 Docs, not from Mail ✗  NOT source app Mail failed
 7 Google              ✓  domain google.com matches docs.google.com
```

## A8. Accessibility

| Setting | Behavior |
|---|---|
| Reduce Transparency | Glass becomes solid: tiles use `.background(.quaternary)` on black; floating panel uses `.background(.windowBackground)`. |
| Reduce Motion | All springs become 150 ms cross-fades; no morphing; lens jumps. |
| Increase Contrast | 1 pt `.separator` borders on tiles and chips; key hints use `.primary`. |
| VoiceOver | Drop announces "Open linear.app from Slack. 5 choices." Each tile: "Chrome, Work profile, key 1". Pulse posts an announcement "Opened in Chrome, Work". |
| Keyboard only | Everything reachable; Drop is fully usable without a mouse. |

## A9. Edge cases in the UI

- **Full-screen app on the notch display:** the menu bar is hidden; the Drop still drops from the top center of that display.
- **Two displays:** the Drop opens on the display with the mouse pointer (PRD F-PICK-7).
- **Very long host** (e.g. a long subdomain): truncate the head, keep the registrable domain visible: `…ci.eu-west-1.acme.com`.
- **Zero targets** (fresh install, catalog empty): Drop shows "No browsers found" and a button to open Settings.
- **Another notch app is active:** user can switch BrowserBro to "always top-center" mode.

---

# Part B: System design

## B1. Overview

```text
            Apple Event "get URL" (+ sender PID)
                         │
                         ▼
┌──────────────────────────────────────────────────────────────┐
│ BrowserBro.app  (agent app, LSUIElement, AppKit + SwiftUI)   │
│                                                              │
│  LinkIntake ──► Router ──► RoutingCore.decide(request) ──┐   │
│      │            │                (pure Swift package)   │   │
│      │            │◄───────────── Decision + trace ◄──────┘   │
│      │            │                                           │
│      │            ├──► Launcher ──► browser process / NSWorkspace
│      │            ├──► DropPresenter (picker panel)           │
│      │            └──► PulsePresenter                         │
│      │                                                        │
│  BrowserCatalog ◄── ProfileReaders (Chromium, Gecko, Safari*) │
│  RuleStore ◄──► rules.json (FSEvents watch, atomic writes)    │
│  Settings UI (SwiftUI)   MenuBarExtra (SwiftUI)               │
└──────────────────────────────────────────────────────────────┘
* Safari profiles: P2, opt-in, needs Accessibility.
```

## B2. Modules

| Module | Kind | Responsibility | Depends on |
|---|---|---|---|
| `RoutingCore` | Swift package, no AppKit | Rule model, JSON codec + schema migration, matchers, `decide()`, trace, conflict analyzer. | Foundation only |
| `LinkIntake` | App | Apple Event handler; extracts URL list, sender bundle ID, modifier flags; builds `RouteRequest`. | AppKit |
| `BrowserCatalog` | App | Lists apps that open `https`; merges profile readers; publishes `[Target]`; watches files. | AppKit, readers |
| `ProfileReaders` | App | `ChromiumProfileReader` (`Local State`), `GeckoProfileReader` (`profiles.ini`), `SafariProfileReader` (P2). | Foundation |
| `Launcher` | App | Per-family launch strategies (§B5). Reports success / failure. | AppKit |
| `Router` | App, `@MainActor` | Glue: request → decision → launcher or Drop; queue for many links; fallback chain. | all above |
| `DropPresenter`, `PulsePresenter` | App | `NSPanel` hosting SwiftUI views; notch geometry; screen selection. | AppKit, SwiftUI |
| `RuleStore` | App | Load / save / watch `rules.json`; keeps last good copy; publishes changes. | RoutingCore |
| `SettingsUI`, `MenuBar` | App | SwiftUI scenes. | Store, catalog |
| `bro` CLI (dev tool) | Executable target | `bro test <url> --from <bundleID> [--option]` prints the trace. Used in CI and while editing rules. | RoutingCore |

## B3. Core types (RoutingCore)

```swift
public struct RouteRequest: Sendable {
    public let url: URL
    public let sourceBundleID: String?      // nil = unknown sender
    public let modifiers: ModifierSet       // option, shift, command, control
}

public struct TargetID: Hashable, Codable, Sendable {
    public let app: String                  // bundle ID
    public let profile: String?             // Chromium dir ("Profile 1"), Gecko profile name/path
}

public enum Condition: Codable, Sendable {
    case domain(String)                     // host == d || host.hasSuffix("." + d)
    case hostIs(String)
    case pathPrefix(String)
    case urlContains(String)
    case wildcard(String)                   // * = one label/segment, ** = anything
    case regex(String)                      // compiled once, cached
    case sourceApp(String)
    case modifier(ModifierSet)
    // P2: case runningApp(String)
}

public struct Rule: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var mode: MatchMode              // .all / .any
    public var conditions: [Negatable<Condition>]
    public var target: TargetID
    public var options: TargetOptions       // privateWindow, openInBackground
}

public enum Decision: Sendable {
    case open(TargetID, TargetOptions, ruleID: UUID)
    case showPicker(reason: PickerReason)   // .noMatch, .override, .brokenTarget(ruleID)
    case openDefault(TargetID)
}

public func decide(_ req: RouteRequest, rules: CompiledRules,
                   available: Set<TargetID>, settings: RoutingSettings) -> (Decision, Trace)
```

- `CompiledRules` is built once per rules change: hosts lower-cased and converted to punycode, regexes compiled, wildcards turned into anchored regexes.
- `decide` is pure and synchronous. That keeps it fast (Finch shows ~5 µs is reachable) and easy to test.

## B4. Link intake details

1. In `applicationWillFinishLaunching` (before launch finishes, so the launching link is not lost), register:
   `NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handle(_:reply:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))`.
2. URL: direct object `keyDirectObject`. If it is a list, iterate.
3. Sender: attribute `keySenderPIDAttr` (`'spid'`) → `NSRunningApplication(processIdentifier:)?.bundleIdentifier`. Fallback: `NSWorkspace.shared.frontmostApplication` (skip if it is BrowserBro). Pattern verified in `finch/Sources/Finch/AppDelegate.swift:68-75`.
4. Modifiers: `NSEvent.modifierFlags` read at receipt time (a class property; reflects keys held right now). To verify in the Phase 0 spike: timing between the click and the event.
5. Default browser: `NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http")` and the same for `https`. macOS shows its own confirmation dialog. Status: compare `NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)` with our bundle URL.
6. `Info.plist`: `CFBundleURLTypes` for `http`, `https` (and `bro` for F-IN-7); `CFBundleDocumentTypes` for `public.html` / `public.xhtml` with role Viewer. To verify in the spike which keys System Settings needs to list the app as a browser.

## B5. Launch strategies

| Family | Without profile | With profile | Private window | Status |
|---|---|---|---|---|
| Safari | `NSWorkspace.open([url], withApplicationAt:)` | P2: AppleScript + Accessibility menu "New \<Profile\> Window" (pattern in `browser-picker/SafariLauncher.swift`) | P2 | Profile = P2, opt-in |
| Chromium (Chrome, Edge, Brave, Vivaldi, Chromium, Canary) | `NSWorkspace.open` | Run `<App>.app/Contents/MacOS/<exe> --profile-directory=<dir> <url>` with `Process`; a running browser receives it through its own single-instance hand-off (pattern in `browser-picker/BrowserLauncher.swift:49-51`) | add `--incognito` | P0, verify per browser |
| Arc, Dia, Opera | `NSWorkspace.open` | Verify in spike; if no reliable flag → browser-level only | Verify | Per-browser table |
| Gecko (Firefox, Dev Edition, Zen, LibreWolf, Waterfox) | `NSWorkspace.open` | Try `--profile <path> <url>`, then `-P <name> <url>` (pattern in `browser-picker/GeckoLauncher.swift`) | `--private-window <url>` | P0, highest risk (§PRD 13) |

- **Open in background:** `NSWorkspace.OpenConfiguration.activates = false` where we use `NSWorkspace`; for `Process` launches, re-activate the previous app after hand-off (best effort).
- **Failure handling:** each strategy returns `.ok` or `.failed(reason)`. On failure, the Router shows the Drop with an inline note "Couldn't open in Firefox · Dev". If the Drop also fails, it opens the link in the system's previous default browser (saved when the user set BrowserBro as default). A link is never dropped (PRD N-5).
- **Loop guard:** never launch a target whose bundle ID equals ours.

## B6. Profile discovery

| Family | File | Fields used |
|---|---|---|
| Chromium | `~/Library/Application Support/<vendor path>/Local State` (e.g. `Google/Chrome`, `BraveSoftware/Brave-Browser`, `Microsoft Edge`) | `profile.info_cache.<dir>.name`; avatar / color fields when present |
| Gecko | `~/Library/Application Support/Firefox/profiles.ini` (and the matching folder for Zen, LibreWolf, Waterfox) | `[ProfileN] Name`, `Path`, `IsRelative` |
| Safari (P2) | Menu scan via Accessibility | Profile names from "File → New … Window" items |

- A small table maps bundle ID → family → vendor path. Unknown Chromium forks can be added by the user ("Browser family: Chromium, data folder: …").
- Files are watched with `DispatchSource.makeFileSystemObjectSource` on the parent folder (files are replaced atomically by browsers, so we watch the folder, not the file).
- Read-only. We never write to browser data.

## B7. Panels and the notch

- `NSPanel` with `styleMask: [.nonactivatingPanel, .borderless]`, `level: .statusBar + 1`, `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false` (SwiftUI draws the shadow).
- Becomes key only while the Drop is shown (`canBecomeKey = true` override) so number keys work; resigns on close.
- Frame: centered on the notch: `x = screen.frame.midX - width/2`, `y = screen.frame.maxY - height`.
- Notch detection: `screen.safeAreaInsets.top > 0` and both `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` are non-nil → notch mode; otherwise top-center glass mode.
- The SwiftUI root view owns the morph: one `@State var phase: .closed | .open` drives the shell shape from the notch rect to the panel rect.

## B8. Storage

- Path: `~/Library/Application Support/BrowserBro/rules.json` (+ `settings.json` for UI settings).
- Atomic write: write to a temp file in the same folder, then `replaceItemAt`.
- On external change: parse → validate (schema version, regex compile, unknown condition types) → if valid, swap; if not, keep the old rules and show an error badge in the menu bar with the JSON line/column.
- `schemaVersion` + migration functions in `RoutingCore`; every migration has a fixture test.
- Recent decisions (menu bar list) live only in memory, max 5.

## B9. Concurrency

- Swift 6 strict concurrency.
- `RoutingCore` types are `Sendable`; `decide()` is a pure function.
- `Router`, presenters and the catalog are `@MainActor` (they touch AppKit).
- Profile reading and file parsing run on a background task; results are published to the main actor.

## B10. Testing

| Layer | Tool | What |
|---|---|---|
| Matchers | Swift Testing, parameterized tests | Each condition type: positive, negative, edge cases (IDN, ports, `notexample.com` vs `example.com`, trailing dots, uppercase hosts). |
| Decide | Swift Testing | Order, NOT, any/all, override modifier, broken target, fallback modes. |
| Corpus | `bro test` in CI | 200 `(url, sender, modifiers) → expected target` pairs in `Tests/corpus.json`. |
| Conflicts | Swift Testing | Covered rule, duplicate rule, invalid regex. |
| Codec | Swift Testing | Round-trip, migrations, invalid files. |
| Launchers | Manual checklist + small integration script | Each browser family, running and not running, with and without profile. |
| UI | Snapshot of SwiftUI views (light/dark, Reduce Transparency) + manual device check | Drop, Pulse, editor. |
| Performance | `OSSignposter` around decide / launch / present; Instruments | Budgets in PRD N-1. |
| Privacy | `nettop -p <pid>` during the manual test session | 0 connections. |

## B11. Project layout

```text
chili-browser-bro/
├── RESEARCH.md  PRD.md  DESIGN.md  ROADMAP.md
├── BrowserBro.xcodeproj
├── App/                         # BrowserBro.app target (AppKit + SwiftUI)
│   ├── Intake/  Catalog/  Launch/  Router/
│   ├── UI/Drop/  UI/Pulse/  UI/Settings/  UI/MenuBar/
│   └── Resources/ (Info.plist, Localizable.xcstrings, Assets)
├── Packages/RoutingCore/        # pure Swift package
│   ├── Sources/RoutingCore/
│   ├── Sources/bro/             # dev CLI
│   └── Tests/RoutingCoreTests/ (+ corpus.json)
└── .github/workflows/ci.yml     # swift test + corpus on macos runner
```
