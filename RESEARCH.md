# Research: open-source browser routing apps for macOS

Date: 2026-10-05
Goal: learn what existing open-source "browser routers" (also called browser pickers or browser choosers) do on macOS, find the gaps, and reuse proven technical patterns for our own app (working name **BrowserBro**).

## 1. Method

- Searched GitHub (`gh search repos`) for: "browser picker", "browser chooser", "browser selector", "browser router", "browser prompter", "default browser", "finicky".
- Pulled the README of each relevant repo with `gh api repos/<owner>/<repo>/readme` and the repo metadata (stars, license, last push, archived flag) on 2026-10-05.
- Read source code where the README was not enough:
  - `expelledboy/finch` → `Sources/Finch/AppDelegate.swift` (how a link and its sender app arrive).
  - `mertizci/browser-picker` → `BrowserLauncher.swift`, `GeckoLauncher.swift`, `SafariLauncher.swift` (how profiles are launched).
  - Finicky wiki page "Configuration (v4)" (raw markdown).
- Read Apple docs for Liquid Glass: `glassEffect(_:in:)` and "Applying Liquid Glass to custom views".
- Read the OmniNotch website and two of its screenshots for the UI direction (see `DESIGN.md`).

**Evidence level.** Features below come from READMEs, docs, and source code. I did **not** install or run any of these apps. "—" means the README does not mention the feature; it may still exist.

## 2. Apps found

### macOS, open source (in scope of the comparison)

| # | App | Repo | License | Stack | Stars | Last push | Status |
|---|---|---|---|---|---|---|---|
| 1 | Finicky | [johnste/finicky](https://github.com/johnste/finicky) | MIT | Go + JS/TS config | 5155 | 2026-09-16 | Active, market leader |
| 2 | Browserosaurus | [will-stone/browserosaurus](https://github.com/will-stone/browserosaurus) | GPL-3.0 | TypeScript, Electron | 2011 | 2025-08-02 | **Archived** |
| 3 | Browserino | [AlexStrNik/Browserino](https://github.com/AlexStrNik/Browserino) | GPL-3.0 | SwiftUI | 438 | 2026-01-08 | Active, small README |
| 4 | Browser Picker | [mertizci/browser-picker](https://github.com/mertizci/browser-picker) | MIT | Swift | 16 | 2026-09-16 | Active, most complete rule UI |
| 5 | AppCat | [rmarinsky/AppCat](https://github.com/rmarinsky/AppCat) | MIT | Swift | 6 | 2026-09-29 | Active, broad scope |
| 6 | BrowSync | [chentao1006/BrowSync](https://github.com/chentao1006/BrowSync) | MIT | Swift + browser extensions | 107 | 2026-09-30 | Active, routing + sync |
| 7 | Linkquisition | [Strobotti/linkquisition](https://github.com/Strobotti/linkquisition) | MIT | Go + Fyne | 36 | 2026-09-28 | Active, cross-platform |
| 8 | Finch | [expelledboy/finch](https://github.com/expelledboy/finch) | MIT | Swift + JavaScriptCore | 7 | 2026-08-29 | Active, tiny and fast |
| 9 | Chowser | [bsreeram08/chowser](https://github.com/bsreeram08/chowser) | MIT | SwiftUI | 8 | 2026-08-26 | Active, feature-heavy |
| 10 | OpenIn (OpenInApp) | [laurenschristian/OpenInApp](https://github.com/laurenschristian/OpenInApp) | MIT | SwiftUI + AppKit | 3 | 2026-08-14 | Active |
| 11 | Browser Clutch | [nikuscs/browser-clutch](https://github.com/nikuscs/browser-clutch) | Other | Swift | 5 | 2026-09-20 | Active |
| 12 | BrowserRouter | [phpgao/BrowserRouter](https://github.com/phpgao/BrowserRouter) | GPL-3.0 | Swift | 5 | 2026-03-25 | Active, unsigned builds |
| 13 | Bowzer | [lailo/bowzer](https://github.com/lailo/bowzer) | Other | Swift | 3 | 2026-05-16 | Active |
| 14 | Objektiv | [nthloop/Objektiv](https://github.com/nthloop/Objektiv) | MIT | Objective-C | 133 | 2021-02-22 | Stale |
| 15 | Default Browser | [apexskier/DefaultBrowser](https://github.com/apexskier/DefaultBrowser) | none | Swift | 80 | 2026-07-08 | Active, "last used browser" model |

### Reference only (not compared in the table)

- **Other platforms:** [sonnyp/Junction](https://github.com/sonnyp/Junction) (Linux, GPL-3.0, 618★), [mortenn/BrowserPicker](https://github.com/mortenn/BrowserPicker) (Windows, MIT, 496★), [nref/BrowseRouter](https://github.com/nref/BrowseRouter) (Windows, MIT, 203★).
- **Closed source / paid (macOS):** Velja, Choosy, OpenIn (Loshadki), Bumpr. Finch's README lists Velja at $8 and Choosy at $10. We do not depend on them; they only set the bar for polish.
- **Helpers:** [kerma/defaultbrowser](https://github.com/kerma/defaultbrowser) (CLI to set the default browser), [sindresorhus/Copy-URL](https://github.com/sindresorhus/Copy-URL) (adds "copy" to picker apps).

## 3. Feature comparison table

Legend: ✅ = documented · 🟡 = partial / limited · ❌ = documented as missing · — = not mentioned

| Feature | Finicky | Browserosaurus | Browserino | Browser Picker (mertizci) | AppCat | BrowSync | Linkquisition | Finch | Chowser | OpenIn | Browser Clutch | BrowserRouter (phpgao) | Bowzer |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Native macOS (no Electron) | 🟡 Go app | ❌ Electron | ✅ | ✅ | ✅ | ✅ | 🟡 Fyne | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Automatic rules | ✅ | ❌ | — | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Picker when no rule matches | ❌ (suggests Browserosaurus) | ✅ | ✅ | ✅ | ✅ | — | ✅ | ❌ | ✅ | ✅ | — | ✅ | ✅ |
| Rule editor in a GUI | ❌ (JS file) | n/a | — | ✅ | ✅ | ✅ | 🟡 | ❌ (JS file) | ✅ | ✅ | ✅ | ✅ | n/a |
| Rules as a text file | ✅ JS/TS | n/a | — | — | — | — | ✅ JSON | ✅ JS | ✅ JSON import/export | ✅ | ✅ JSON | — | n/a |
| Match: domain / host | ✅ | n/a | — | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | n/a |
| Match: path / query | ✅ | n/a | — | ✅ | 🟡 URL contains | ✅ | 🟡 regex | ✅ regex | ✅ | ✅ | 🟡 | ✅ | n/a |
| Match: regex | ✅ | n/a | — | ✅ | ✅ | — | ✅ | ✅ | — | ✅ | ✅ | ❌ (wildcards) | n/a |
| Match: custom code | ✅ JS | n/a | — | ❌ | ❌ | ❌ | 🟡 plugins | ✅ JS | ❌ | ❌ | ❌ | ❌ | n/a |
| Match: source app (who opened the link) | ✅ `opener` | ❌ | — | ✅ | — | ✅ | — | ✅ `from()` | ✅ | ✅ | ✅ | — | n/a |
| Match: modifier key held | ✅ `getModifierKeys()` | — | — | — | — | — | — | — | — | — | — | 🟡 ⌘ forces picker | — |
| AND / OR / NOT in one rule | ✅ via JS | n/a | — | ✅ | — | — | — | ✅ via JS | — | — | — | — | n/a |
| Rule priority control | ✅ order in file | n/a | — | ✅ drag | — | — | — | ✅ order | — | — | ✅ | — | n/a |
| Rule tester (dry run) | — | n/a | — | ✅ | — | — | ✅ CLI | — | — | — | — | ✅ | n/a |
| Rule conflict warnings | — | n/a | — | ✅ | — | — | — | — | — | — | — | — | n/a |
| "Remember choice" → rule | — | — | — | — | 🟡 suggestions | — | ✅ | — | ✅ press R | — | — | ✅ quick-add | — |
| Chromium profiles | ✅ | ❌ | — | ✅ | ✅ | — | 🟡 manual entry | 🟡 via args | ✅ | ✅ | ❌ (roadmap) | — | ✅ |
| Firefox-family profiles | — | ❌ | — | ✅ (+ Zen) | ✅ | — | 🟡 manual entry | 🟡 via args | ✅ | ✅ | ❌ | — | ✅ |
| Safari profiles | — | ❌ | — | ✅ (needs Full Disk Access + Accessibility) | — | — | — | — | — | — | ❌ | — | — |
| Private / incognito window | — | — | — | — | ✅ ⌥/⇧ | — | — | 🟡 via args | ✅ | ✅ per rule | ✅ | ✅ hover | — |
| Keyboard selection in picker | n/a | ✅ | ✅ | — | ✅ | n/a | ✅ 1–9 | n/a | ✅ | ✅ 1–9 | n/a | — | ✅ 1–9 |
| URL rewriting (out of our scope) | ✅ | ❌ | — | ❌ | ❌ | — | ✅ plugins | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| Extra scope beyond routing | browser extensions | — | — | — | file picker, window switcher, stats | bookmark/cookie/tab sync, iCloud | WHOIS, QR, URL safety | recents menu | unshortener, MCP API, send to phone | recents | — | click stats | — |
| Network calls / third-party services | update check | — | — | GitHub updates | Google S2 favicons, Sparkle | local WebSocket, iCloud | optional Google favicons, Safe Browsing / VirusTotal API keys | none stated | Sparkle, hosted rewrite catalog | — | — | — | — |
| Works with zero permissions | ✅ | ✅ | ✅ | ✅ Basic mode | 🟡 (Accessibility for switcher) | 🟡 extensions | ✅ | ✅ | — | — | ✅ | ✅ | ✅ |

Sources for each cell: the README of each repo (fetched 2026-10-05), plus the Finicky v4 wiki and Finch's own `COMPARISON` table for Finicky's caller-app support.

## 4. What the market tells us

1. **Two camps, few bridges.** Finicky and Finch are "power user, rules in code, no picker". Browserosaurus, Browserino and Bowzer are "picker, no rules". Only a few small, young apps (Browser Picker, Chowser, OpenIn, AppCat) do both well.
2. **The leader is code-only.** Finicky (5155★) has no GUI rule editor and no picker. Its README sends picker users to Browserosaurus, which is now archived. This is the clearest gap.
3. **Profiles are the hard part.** Many apps stop at "which browser". Profile support differs per browser family and is often partial. Safari profiles need extra permissions (Full Disk Access + Accessibility) in the one app that supports them.
4. **Scope creep is common.** AppCat adds a window switcher; BrowSync adds cookie and bookmark sync; Chowser adds an AI (MCP) API and "send to phone"; Linkquisition adds WHOIS and URL safety. These are not needed for routing and they add network calls or permissions.
5. **Quality tools are rare.** Only Browser Picker (mertizci) has rule conflict warnings. Only it, Linkquisition and BrowserRouter have a dry-run tester. These matter more than extra conditions: a router that silently picks the wrong profile is worse than no router.
6. **Privacy leaks hide in small features.** Favicons via Google S2 (AppCat, Linkquisition option) send every visited host to Google. Our app must make **zero** network calls.
7. **Design is plain.** Most pickers are a floating row of icons near the cursor. Only BrowserRouter mentions a "frosted-glass" dock. Nobody uses the MacBook notch or the new Liquid Glass material.

## 5. Technical findings we will reuse

All checked in source code or docs (paths below).

| Topic | Finding | Source |
|---|---|---|
| Receive links | Register an Apple Event handler with `NSAppleEventManager.shared().setEventHandler(...)` for the "get URL" event. The URL is the direct object (`'----'`). | `finch/Sources/Finch/AppDelegate.swift:16,45-46` |
| Know the sender app | Read the sender process ID attribute `'spid'` from the event, then `NSRunningApplication(processIdentifier:)` → bundle ID. Fallback: `NSWorkspace.shared.frontmostApplication`. | `finch/Sources/Finch/AppDelegate.swift:6,68-75` |
| Open in a browser (no profile) | `NSWorkspace.shared.open([url], withApplicationAt:configuration:)`. | `finch/.../AppDelegate.swift:95-97`, `browser-picker/.../BrowserLauncher.swift:16` |
| Chromium profile | Run the browser executable with `--profile-directory=<dir>` and the URL (via `Process`), so a running browser receives it. | `browser-picker/.../BrowserLauncher.swift:49-51` |
| Firefox profile | Try `--profile <path> <url>`, then `-P <name> <url>`, then `-P <name> -no-remote <url>`. Several attempts are needed, which hints that this is fragile. | `browser-picker/.../GeckoLauncher.swift:10-35` |
| Safari profile | No CLI. Uses AppleScript + Accessibility to click "File → New <Profile> Window". Fragile and needs permissions. | `browser-picker/.../SafariLauncher.swift:5-118` |
| Profile discovery | Chromium family: `Local State` JSON. Firefox family: `profiles.ini`. Safari: `SafariTabs.db` (needs Full Disk Access) or a menu scan. | mertizci README "Browser-specific behavior" |
| Host-suffix trap | A plain suffix match treats `notexample.com` as a match for `example.com`. Our "domain" condition must check the dot boundary. | mertizci README "Host suffix" note |
| Speed | Finch measures ~5 µs per routing decision in Swift. Rule evaluation is never the bottleneck; browser launch is. | Finch README "Performance" |
| Liquid Glass | SwiftUI `glassEffect(_:in:)` (default `.regular` in a capsule), `.tint(_:)`, `.interactive()`, and `GlassEffectContainer` to blend and morph shapes. | developer.apple.com: `glassEffect(_:in:)`, "Applying Liquid Glass to custom views" |

## 6. Conclusions for BrowserBro

- **Build, do not fork.** The best rule UI (mertizci, MIT) is young (16★). Finicky is Go-based and code-only. A clean Swift codebase with a tested core package is cheaper than bending either one. We may read their code for patterns (MIT allows it; we will not copy GPL code from Browserino, Browserosaurus or BrowserRouter).
- **Our position:** "Finicky's rule power, with a GUI, a tester and conflict checks, for browsers **and profiles**, in a notch-native Liquid Glass picker, with zero network calls."
- **Strict scope:** rule-based link → browser/profile selection only. No URL rewriting, no sync, no history analytics, no AI, no favicons from the web. See the non-goals in `PRD.md`.
