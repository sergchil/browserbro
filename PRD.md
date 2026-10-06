# PRD: BrowserBro

Product Requirements Document (PRD)
Status: Draft v1 · Date: 2026-10-05 · Owner: Sergey Chilingaryan
Related: `RESEARCH.md` (market and tech findings), `DESIGN.md` (UI and system design), `ROADMAP.md` (phases)

## 1. Summary

BrowserBro is a native macOS app that becomes the system default browser. When you click a link in any app, BrowserBro decides **which browser and which profile** should open it:

1. If a rule matches, it opens the link there right away.
2. If no rule matches, it shows a small Liquid Glass picker right next to the mouse pointer, where you clicked the link. One key press opens the link, and you can save the choice as a new rule.

It runs fully on device. It makes no network calls and uses no paid services.

## 2. Problem

People who keep work and personal life in separate browsers or profiles lose time and make mistakes:

- A Linear or Slack link opens in the personal Chrome profile, which is not logged in to work tools.
- A personal link opens inside the work profile and mixes history and cookies.
- macOS lets you pick only **one** default browser and has no idea of profiles.

Existing open-source tools solve half of this (see `RESEARCH.md` §4):

- Finicky has strong rules but no GUI and no picker.
- Picker apps have no rules, or weak profile support, or extra features that call the network.
- Few tools let you test a rule or warn you about rule conflicts.

## 3. Goals

| ID | Goal | How we measure it (all local) |
|---|---|---|
| G1 | Every link lands in the right browser **and** profile. | 0 wrong routes on the test corpus of 200 URL + sender pairs (`ROADMAP.md` Phase 1). |
| G2 | Routing feels instant. | Rule decision < 1 ms (p99). Link-to-handoff overhead < 50 ms when the target browser runs. |
| G3 | Writing rules is easy and safe. | A new user creates a working source-app rule in < 60 s with the GUI. Every conflict is shown before save. |
| G4 | Manual choice is one key press. | Picker visible < 150 ms after the click; open with `1`–`9` or `Return`. |
| G5 | Private by design. | 0 outbound network connections (checked with Little Snitch / `nettop` during the test run). |

## 4. Non-goals (hard scope limits)

BrowserBro does **rule-based link → browser/profile selection** and nothing else. These are out of scope for all phases:

- URL rewriting, tracking-parameter removal, link unshortening, force-HTTPS.
- Bookmark, cookie, tab, or session sync.
- Browsing history, statistics dashboards, "time saved" counters.
- AI features (rule suggestions by a model, MCP / agent APIs, chat).
- Favicons or page titles fetched from the web; URL safety checks (Safe Browsing, VirusTotal); WHOIS; QR codes; "send to phone".
- Opening files with other apps; app or window switching.
- Cloud sync of settings (iCloud or other). Rules are a local file; users can sync that file themselves.
- Paid services of any kind, including the paid Apple Developer Program for notarization (see §9).
- Non-macOS platforms.

## 5. Users

| Persona | Need | Example |
|---|---|---|
| **The split worker** (primary) | Work and personal profiles in one browser. | Slack, Linear, Google Meet and `*.acme.com` → Chrome "Work" profile. Everything else → Safari. |
| **The multi-browser dev** | Different browsers for different jobs. | `localhost:*` → Chrome Canary. GitHub from Terminal → Firefox "Dev". |
| **The occasional chooser** | No rules; wants to pick each time. | Picker always, with number keys. |

## 6. User stories

1. As a split worker, I click a Linear link in Slack and it opens in Chrome "Work", without any prompt.
2. As a split worker, I click an unknown link and a picker shows my browsers and profiles; I press `2` and tick "Always for this site".
3. As a dev, I hold `⌥` (Option) while clicking a link to force the picker, even if a rule matches.
4. As any user, I paste a URL into the tester, choose "from Slack", and see which rule wins and why each other rule failed.
5. As any user, when I add a rule that an earlier rule already covers, I see a warning before I save.
6. As any user, I see a short "pulse" next to the pointer telling me where a link went, and I can click it to re-open the link somewhere else.
7. As a power user, I edit `rules.json` in my editor and the app reloads it; if the file is invalid, the app keeps the last good rules and tells me the line with the error.

## 7. Functional requirements

Priority: **P0** = MVP, must ship · **P1** = v1.0 · **P2** = later, still in scope.

### 7.1 Link intake

| ID | Pri | Requirement |
|---|---|---|
| F-IN-1 | P0 | Register for `http` and `https` URL schemes and HTML document types, so the app appears in System Settings → Desktop & Dock → Default web browser. |
| F-IN-2 | P0 | "Set as default browser" button that calls the system API and shows the system confirmation. Show the current status in the menu bar and settings. |
| F-IN-3 | P0 | Receive links through the Apple Event "get URL" handler. Handle several URLs in one event (each one routed on its own). |
| F-IN-4 | P0 | Capture the **sender app** (bundle ID) from the event's sender process ID. Fallback: frontmost app. If both fail, sender = unknown. |
| F-IN-5 | P0 | Capture **modifier keys** (⌥ ⇧ ⌘ ⌃) held at the moment the link arrives. |
| F-IN-6 | P0 | Cold start: if the app was not running, the link that launched it is still routed (no lost links). |
| F-IN-7 | P1 | Accept `bro://open?url=<encoded>` so Shortcuts, Raycast or scripts can send links in. |

### 7.2 Browser and profile catalog

| ID | Pri | Requirement |
|---|---|---|
| F-CAT-1 | P0 | Detect installed apps that can open `https` URLs (excluding BrowserBro). |
| F-CAT-2 | P0 | Read Chromium-family profiles (Chrome, Chrome Canary, Edge, Brave, Vivaldi, Arc if supported, Chromium, Dia, Opera if supported) from each browser's `Local State`. |
| F-CAT-3 | P0 | Read Firefox-family profiles (Firefox, Firefox Developer Edition, Zen, LibreWolf, Waterfox) from `profiles.ini`. |
| F-CAT-4 | P0 | Every target has a stable ID: `<bundleID>` or `<bundleID>#<profileKey>`. Rules store the ID, not the display name. |
| F-CAT-5 | P0 | Watch profile files; refresh the catalog when a profile is added, renamed or removed. |
| F-CAT-6 | P1 | Show / hide / reorder targets; set a custom label and a custom number key per target. |
| F-CAT-7 | P1 | If a rule points to a missing target (browser removed, profile deleted), mark the rule as broken and fall back to the picker. Never drop the link. |
| F-CAT-8 | P2 | Safari profiles (needs Accessibility; opt-in only, off by default). |

### 7.3 Rule engine

A rule = **conditions** + **target** + **options**. Rules are ordered; the **first enabled rule that matches wins**.

| ID | Pri | Requirement |
|---|---|---|
| F-RULE-1 | P0 | Condition types: **Domain** (host or any subdomain, dot-boundary safe), **Host is** (exact), **Path starts with**, **URL contains**, **Wildcard** (`*` = one label/segment, `**` = anything), **Regex** (full URL), **Source app** (bundle ID), **Modifier held**. |
| F-RULE-2 | P0 | Combine conditions with **All** (AND) or **Any** (OR); each condition can be negated (NOT). |
| F-RULE-3 | P0 | Target = browser, or browser + profile. Options: **private window** (where the browser supports it), **open in background** (no focus change). |
| F-RULE-4 | P0 | Rule order = priority. Enable / disable per rule. |
| F-RULE-5 | P0 | Fallback when nothing matches: **Show picker** (default) or **Open in default target**. |
| F-RULE-6 | P0 | Override: a configurable modifier (default `⌥`) forces the picker, even when a rule matches. |
| F-RULE-7 | P0 | Matching is case-insensitive for host, case-sensitive for path (documented in the UI). Internationalized domains are compared in punycode. |
| F-RULE-8 | P0 | Pure, deterministic engine with a **trace**: for each rule, matched or not and which condition failed. |
| F-RULE-9 | P1 | **Conflict analysis:** warn when a rule is fully covered by an earlier rule (it can never fire), when two rules have the same conditions but different targets, and when a regex does not compile. |
| F-RULE-10 | P2 | **Running app** condition (e.g. "Zoom is running"). |

### 7.4 Picker

| ID | Pri | Requirement |
|---|---|---|
| F-PICK-1 | P0 | Show the picker when no rule matches, or on override. It shows the host, the full URL (truncated in the middle), the sender app, and the targets. |
| F-PICK-2 | P0 | Keys: `1`–`9` open a target; arrows + `Return`; `Esc` cancels (link is not opened). |
| F-PICK-3 | P0 | Mouse: click a target. |
| F-PICK-4 | P1 | "Always open \<domain\> here" toggle (`Tab` toggles it). When on, choosing a target also creates a Domain rule at the end of the rule list, and shows a conflict warning if needed. |
| F-PICK-5 | P1 | `⌥` + choice = open in a private window (if supported). |
| F-PICK-6 | P1 | The picker is a floating Liquid Glass card that opens next to the mouse pointer: the icon of target 1 sits under the pointer, and the card grows out of it with a spring. It always stays inside the visible screen. Tiles show the profile first, the browser second. Style: see `DESIGN.md` §A4. |
| F-PICK-7 | P1 | The picker opens on the display that has the mouse pointer, at the pointer. Same behavior on every display and in full-screen Spaces. |
| F-PICK-8 | P1 | If several links arrive while the picker is open, queue them and show "1 of 3". |

### 7.5 Feedback

| ID | Pri | Requirement |
|---|---|---|
| F-FB-1 | P1 | "Routed" pulse: after a rule routes a link, a small glass capsule just below-right of the pointer shows the target for ~1.6 s (longer while hovered). Clicking it opens the picker for that same link ("open elsewhere"). Can be turned off. |
| F-FB-2 | P1 | Menu bar item shows the last 5 routing decisions (in memory only, cleared on quit) with the rule name, for debugging. |

### 7.6 Settings and rule management

| ID | Pri | Requirement |
|---|---|---|
| F-SET-1 | P1 | Settings window: General, Browsers & Profiles, Rules, Tester, About. |
| F-SET-2 | P1 | Rule editor that reads as a sentence: "When **all** of these match … open in **Chrome · Work**". |
| F-SET-3 | P1 | Drag to reorder; duplicate; enable toggle; inline conflict badges. |
| F-SET-4 | P1 | **Tester:** URL + sender app + modifiers → winning rule, target, and the full trace. Never opens a browser. |
| F-SET-5 | P0 | Rules live in `~/Library/Application Support/BrowserBro/rules.json` (versioned schema, human-editable). Atomic writes. External edits are reloaded; invalid files are rejected with a clear error and the last good rules stay active. |
| F-SET-6 | P1 | Import / export the rules file. |
| F-SET-7 | P1 | Launch at login (`SMAppService`). |
| F-SET-8 | P2 | Import a simple Finicky config (static `handlers` with string / regex `match` and `browser` + `profile`). Function-based matchers are listed as "not imported". |

## 8. Non-functional requirements

| ID | Area | Requirement |
|---|---|---|
| N-1 | Performance | Rule decision p99 < 1 ms for 200 rules. Warm handoff overhead < 50 ms. Cold start (app not running) to handoff < 400 ms. Picker visible < 150 ms. |
| N-2 | Resources | Idle memory < 40 MB. Idle CPU ≈ 0% (no polling; file watching uses FSEvents / dispatch sources). |
| N-3 | Privacy | No network access at all: no favicons, no update checks, no crash reporting, no analytics. Logs use `os.Logger` with URLs marked private. |
| N-4 | Permissions | Core features need **no** special permissions. Accessibility is asked only if the user turns on Safari profiles (P2). |
| N-5 | Reliability | A link is never lost: on any error the app falls back to the picker, then to the system's previous default browser. |
| N-6 | Accessibility | Full keyboard use; VoiceOver labels; respects Reduce Transparency, Reduce Motion, Increase Contrast. |
| N-7 | Platform | macOS 14 (Sonoma) or later, Apple silicon and Intel (universal binary). Liquid Glass on macOS 26; on macOS 14–15 the same UI uses classic materials (one set of views, small `#available` helpers in `Glass.swift`). |
| N-8 | Quality | Core engine coverage ≥ 90% lines; every condition type has table tests; the 200-pair routing corpus runs in CI. |
| N-9 | Localization | English first; all strings in a String Catalog so more languages can be added later. |

## 9. Constraints

- **No paid third-party services.** No paid APIs, no paid hosting, no paid analytics.
- **Distribution without paid Apple membership.** Notarization needs the paid Apple Developer Program, so we do not depend on it. Users build from source with Xcode (a free Apple ID is enough for local signing) or install an ad-hoc signed build from GitHub Releases and confirm it once in System Settings → Privacy & Security. A personal Homebrew tap is optional (free).
- **Free tooling only:** Xcode, Swift 6, Swift Package Manager, Swift Testing, GitHub Actions (free for public repos).
- **License:** MIT for our code. No GPL code is copied in (Browserino, Browserosaurus, BrowserRouter are GPL-3.0).

## 10. Rule file format (P0)

```json
{
  "schemaVersion": 1,
  "fallback": { "kind": "picker" },
  "pickerOverrideModifier": "option",
  "rules": [
    {
      "id": "6c1f…",
      "name": "Work tools",
      "enabled": true,
      "match": {
        "mode": "any",
        "conditions": [
          { "type": "domain", "value": "linear.app" },
          { "type": "domain", "value": "slack.com" },
          { "type": "sourceApp", "value": "com.tinyspeck.slackmacgap" }
        ]
      },
      "target": { "app": "com.google.Chrome", "profile": "Profile 1" },
      "options": { "privateWindow": false, "openInBackground": false }
    },
    {
      "id": "9a07…",
      "name": "Docs, not from Mail",
      "enabled": true,
      "match": {
        "mode": "all",
        "conditions": [
          { "type": "domain", "value": "docs.google.com" },
          { "type": "sourceApp", "value": "com.apple.mail", "negate": true }
        ]
      },
      "target": { "app": "org.mozilla.firefox", "profile": "Personal" }
    }
  ]
}
```

## 11. Routing decision order

```text
link arrives (URL, sender app, modifiers)
        │
        ▼
override modifier held? ──yes──► picker
        │ no
        ▼
first enabled rule that matches? ──yes──► target exists? ──yes──► open in target (+ pulse)
        │ no                                     │ no
        ▼                                        ▼
fallback = picker? ──yes──► picker          picker (rule marked broken)
        │ no
        ▼
open in default target
```

## 12. Acceptance criteria for v1.0

- All P0 and P1 requirements are met and covered by tests or a recorded manual check.
- The 200-pair corpus routes with 0 errors.
- Performance budgets in N-1 are met on an M-series MacBook (measured with signposts in Instruments).
- No outbound connection during a 1-hour daily-use session (N-3).
- Works with: Safari, Chrome (2+ profiles), Firefox (2+ profiles), Arc or Brave, Zen.
- Works on: MacBook built-in display, external display, two displays at once, a full-screen Space.

## 13. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Firefox does not accept a second profile while another profile runs. | Wrong profile or an error dialog. | Spike in Phase 0. Try `--profile <path>`, then `-P <name>`; detect failure; fall back to the picker with a clear message. |
| Chromium-family browsers differ in flags (Arc, Dia, Opera). | Profile routing fails for some browsers. | Per-browser "launch strategy" table; ship only browsers verified on device; others = browser-level only. |
| Sender PID is missing for some apps (e.g. links from Terminal via `open`). | Source-app rules miss. | Fallback to frontmost app; show "sender unknown" in tester and picker. |
| macOS changes default-browser APIs or prompts. | Setup breaks. | Use public APIs only; status check on every launch. |
| Unsigned / ad-hoc builds scare users. | Fewer users. | Clear build-from-source docs; this is a personal-first tool. |
| Picker at the pointer lands near a screen edge, or covers what the user was reading. | Tile 1 is not under the pointer; content is hidden for a moment. | Clamp the card to the visible screen; it closes on any click outside or `Esc`; the panel is short-lived. |

## 14. Decisions made (can be changed)

- **macOS 14+, Liquid Glass on 26.** v1.0 was macOS 26 only. From v1.1 the app runs on macOS 14 Sonoma and later. Only the picker and the pulse use glass APIs, so the fallback is small: `Glass.swift` wraps every macOS-26-only call and uses material + hairline + shadow on 14–15. `BROWSERBRO_FORCE_LEGACY_UI=1` shows the fallback on macOS 26 for checks. Universal binary (Apple silicon and Intel): it costs only build time.
- **Native Swift, not Tauri or GPUI.** The app is mostly macOS APIs: the URL Apple Event with the sender app, the default-browser API, a non-activating panel at the pointer, AppleScript for Arc, `SMAppService` for launch at login. Native Liquid Glass exists only in AppKit and SwiftUI. Tauri is a web view (about 60–150 MB RAM, slower cold start when a link is clicked). GPUI draws everything itself: no native controls, and its API is not stable. If we go cross-platform later, we port only `RoutingCore`.
- **First match wins**, ordered list. No scoring or weights: easy to explain and to test.
- **Picker is the default fallback**, not "open in default browser", so unknown links are never misrouted.
- **Picker opens at the mouse pointer**, not at the top of the screen: the user's eyes and hand are already there, and choice 1 needs no mouse travel.
- **No URL rewriting**, even though Finicky, Finch and Chowser have it: it is outside rule-based selection.
- **JSON, not JavaScript**, for rules: safe to edit from the GUI and to analyze for conflicts. Custom code matchers stay out.
