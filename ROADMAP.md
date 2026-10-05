# Roadmap: BrowserBro

Phased plan from empty folder to v1.0. Each phase ends with a **proof**: something you can run or see, not a report.
Related: `PRD.md` (requirement IDs), `DESIGN.md` (UI and system design), `RESEARCH.md`.

Estimates assume AI-assisted coding (agents write most code). Most time goes to device checks across browsers, not to typing code.

## Overview

```text
Phase 0  Spikes (de-risk)            ██            ~2 days
Phase 1  RoutingCore + CLI             ███          ~3 days
Phase 2  MVP: route by rules file         ███       ~3 days    ← daily use starts here
Phase 3  The Drop + Pulse (glass UI)         ████   ~4 days
Phase 4  Settings, editor, tester               ████ ~4 days
Phase 5  Hardening + v1.0 release                 ███ ~3 days
Phase 6  P2 items (optional, in scope)              ██+ as needed
```

Total to v1.0: about 4 weeks of part-time work (estimate, not measured).

---

## Phase 0: Spikes (de-risk the unknowns)

**Goal:** prove the 5 risky platform behaviors on a real Mac before writing the product. Throwaway code in `spikes/`.

| Spike | Question | Pass when |
|---|---|---|
| S1 Default browser | Which `Info.plist` keys make the app show up in System Settings → Default web browser? Does `setDefaultApplication(at:toOpenURLsWithScheme:)` work for both `http` and `https`? | App appears in the list; one call sets it; a link from Slack reaches the handler. |
| S2 Sender + modifiers | Do we get the `'spid'` sender for Slack, Mail, Messages, Terminal (`open https://…`), Notes, Linear desktop? Is `NSEvent.modifierFlags` still correct when the event arrives? | Table of apps → sender result; ⌥-click detected in ≥ 9 of 10 tries. |
| S3 Chromium profiles | Does `--profile-directory=` hand off to a **running** Chrome, Brave, Edge, Vivaldi? Arc, Dia, Opera? | Per-browser yes/no table, recorded with screenshots. |
| S4 Gecko profiles | Firefox and Zen: open a link in profile B while profile A runs. Which argument set works? | A working argument set, or a documented "not possible" with the error. |
| S5 Notch panel | `NSPanel` over the menu bar at the notch, takes number keys, does not steal focus, works in full-screen Spaces; `glassEffect` renders inside it. | Screen recording on a notch MacBook + an external display. |

**Deliverable:** `spikes/FINDINGS.md` with the tables above. Update `DESIGN.md` §B4–B7 and the PRD risk table with the results.
**Exit:** every P0 launch path is either proven, or moved to "browser-level only" in the PRD.

---

## Phase 1: RoutingCore package + `bro` CLI

**Goal:** the brain, fully tested, with no UI.
**Requirements:** F-RULE-1…8, F-SET-5 (codec part), N-1 (decision budget), N-8.

Tasks:
1. Create `Packages/RoutingCore` (Swift 6, strict concurrency, Swift Testing).
2. Types from `DESIGN.md` §B3: `RouteRequest`, `TargetID`, `Condition`, `Rule`, `Decision`, `Trace`.
3. Matchers: domain (dot-boundary), hostIs, pathPrefix, urlContains, wildcard, regex, sourceApp, modifier; NOT; all/any.
4. `CompiledRules` (punycode, regex cache, wildcard → anchored regex).
5. `decide()` with override modifier, broken target and fallback modes.
6. JSON codec with `schemaVersion: 1`, validation errors with line/column.
7. `bro` CLI: `bro test <url> [--from <bundleID>] [--option|--shift|--command] [--rules <path>]`.
8. Test corpus: 200 pairs in `Tests/corpus.json` (work domains, personal, localhost, IDN, ports, tricky suffixes).
9. CI: GitHub Actions `macos` runner runs `swift test` and the corpus.

**Proof:**
```bash
cd Packages/RoutingCore && swift test
swift run bro test "https://linear.app/x" --from com.tinyspeck.slackmacgap --rules Tests/fixtures/rules.json
# → Rule 1 "Work tools" → com.google.Chrome#Profile 1   (+ trace)
```
**Exit:** all tests green; corpus 200/200; `decide()` p99 < 1 ms for 200 rules (benchmark test).

---

## Phase 2: MVP app (route by rules file)

**Goal:** BrowserBro is the default browser and routes links correctly using a hand-edited `rules.json`. No picker yet: fallback opens the default target.
**Requirements:** F-IN-1…6, F-CAT-1…5, F-RULE-5 (default-target mode), F-SET-5, N-3, N-5.

Tasks:
1. Xcode app target, agent app (`LSUIElement`), macOS 26 minimum, links `RoutingCore`.
2. `LinkIntake` (Apple Event handler, sender, modifiers, multi-URL, cold start).
3. `BrowserCatalog` + Chromium and Gecko profile readers + folder watching.
4. `Launcher` strategies proven in Phase 0; failure chain (picker placeholder → previous default browser).
5. `RuleStore`: load, watch, validate, keep last good copy.
6. Minimal `MenuBarExtra`: default-browser status + "Set as default", "Reveal rules file", last 5 decisions, Quit.

**Proof (manual, on device):**
- Slack → Linear link opens in Chrome "Work"; Mail → same link opens in Firefox (rule with NOT source).
- Edit `rules.json` in an editor → next click uses the new rule; a broken JSON shows an error badge and old rules keep working.
- Quit the app, click a link → app launches and routes it (cold start).
- `nettop -p $(pgrep BrowserBro)` shows no connections during the session.

**Exit:** Sergey uses it as his default browser for 2 working days with no lost or misrouted link. **This is the first usable release (v0.1).**

---

## Phase 3: The Drop and the Pulse (Liquid Glass UI)

**Goal:** the notch-native picker and the routed toast from `DESIGN.md` §A4–A5.
**Requirements:** F-PICK-1…8, F-RULE-6, F-FB-1, N-6 (picker part).

Tasks:
1. `DropPresenter`: `NSPanel` setup, notch geometry from `NSScreen`, screen with the pointer, notch vs top-center mode.
2. Shell `Shape` with concave ears and continuous bottom corners; spring morph from the notch rect.
3. Tiles + lens inside `GlassEffectContainer`; `glassEffectID` morph; profile tint.
4. Keyboard: 1–9, arrows, Return, Esc, ⌥ private, Tab "Always open here" (creates a Domain rule + conflict check from RoutingCore).
5. Queue for many links ("1 of 3").
6. `PulsePresenter`: widened-notch toast, hover-to-hold, click → Drop for the same link.
7. Override modifier (default ⌥) forces the Drop.
8. Reduce Transparency / Reduce Motion / Increase Contrast variants; VoiceOver labels and announcements.

**Proof:** screen recordings on (a) a notch MacBook, (b) an external display, (c) with Reduce Motion and Reduce Transparency on. Signpost trace shows Drop visible < 150 ms after the event.
**Exit:** fallback setting defaults to "Show picker"; Phase 2 proofs still pass. **v0.2.**

---

## Phase 4: Settings, rule editor, tester

**Goal:** no need to touch JSON anymore.
**Requirements:** F-SET-1…4, F-SET-6, F-SET-7, F-CAT-6, F-CAT-7, F-RULE-9, F-IN-7.

Tasks:
1. Settings window (`NavigationSplitView`): General, Browsers & Profiles, Rules, Tester, About.
2. Browsers & Profiles: show/hide, reorder, custom key and label; broken-target warnings.
3. Rules list: drag reorder, enable toggle, duplicate, delete, conflict badges.
4. Sentence-style rule editor with source-app search and live mini-tester.
5. Conflict analyzer in `RoutingCore` (covered rule, duplicate conditions with different targets, bad regex) + tests.
6. Tester view with full trace (same code path as `bro test`).
7. Import / export rules; launch at login (`SMAppService`); `bro://open?url=` scheme.

**Proof:** a new user (or Sergey on a clean macOS user account) creates "Slack links → Chrome Work" in under 60 s; a deliberately covered rule shows the warning before save; Tester result equals `bro test` output for 20 sample URLs.
**Exit:** all P1 requirements done except release items. **v0.3.**

---

## Phase 5: Hardening and v1.0 release

**Goal:** meet every v1.0 acceptance criterion in `PRD.md` §12.

Tasks:
1. Browser matrix run: Safari, Chrome (2+ profiles), Firefox (2+ profiles), Brave or Arc, Zen — each running and not running.
2. Display matrix: notch MacBook, external monitor, two displays, full-screen Space.
3. Performance pass with Instruments against N-1 and N-2 budgets.
4. Privacy pass: 1-hour session with `nettop` → 0 connections.
5. Onboarding: first launch window (set default browser → pick fallback → optional first rule).
6. String Catalog complete; README with build-from-source steps.
7. Release: ad-hoc signed `.zip`/`.dmg` on GitHub Releases (free), with the one-time "Open Anyway" instructions; optional personal Homebrew tap. No paid notarization.

**Proof:** checklist in `docs/release-checklist.md` fully ticked with links to recordings / outputs.
**Exit:** **v1.0 tagged.**

---

## Phase 6: P2 items (optional, still inside the scope)

Pick by need; each is independent.

| Item | Requirement | Note |
|---|---|---|
| Safari profiles | F-CAT-8 | Opt-in; needs Accessibility; menu automation is fragile across macOS versions. |
| "Running app" condition | F-RULE-10 | e.g. route Meet links to Chrome only while Zoom is not running. |
| Finicky config import | F-SET-8 | Static handlers only; function matchers listed as not imported. |
| More browsers' profile support | F-CAT-2/3 | Only after a device check per browser. |

---

## Parking lot (out of scope, do not build)

Listed so they are not re-proposed: URL rewriting / tracking strip, unshortener, sync of any kind, history or stats, AI rule suggestions, MCP API, favicons from the web, URL safety checks, QR / send to phone, file "open with", window switcher, iCloud settings sync. Reason: `PRD.md` §4.

## Risk tracking per phase

| Risk (PRD §13) | Retired in |
|---|---|
| Gecko second-profile launch | Phase 0 (S4) |
| Chromium-family flag differences | Phase 0 (S3), confirmed in Phase 5 matrix |
| Missing sender PID | Phase 0 (S2) |
| Default-browser API behavior | Phase 0 (S1) |
| Notch panel focus / Spaces issues | Phase 0 (S5), Phase 3 |
| Unsigned build friction | Phase 5 docs |

## Definition of done (every phase)

- Code merged on `main`, CI green (`swift test` + corpus).
- The phase proof is recorded (command output, screenshot or screen recording) and linked in the phase's PR.
- `PRD.md` / `DESIGN.md` updated if a finding changed a decision.
- No new network call, no new permission, no out-of-scope feature.
