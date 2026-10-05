---
name: browserbro-release
description: "Use when releasing a new BrowserBro version. Tag, verify assets, bump the Homebrew cask, test installs."
---

# Release BrowserBro

## Steps

1. `swift test` green on `main`; `scripts/build-app.sh` and `--self-test` pass (with `BROWSERBRO_SUPPORT_DIR=$(mktemp -d)`).
2. Tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`. The Release workflow builds on `macos-26` and creates the release.
3. Check the release: `gh release view vX.Y.Z -R sergchil/browserbro --json assets` → DMG, ZIP, both `.sha256`, plus stable `BrowserBro.dmg` / `BrowserBro.zip` (+ their `.sha256`): 8 assets.
4. Bump the cask in `sergchil/homebrew-tap` → `Casks/browserbro.rb`: `version` and `sha256` of the new `BrowserBro-X.Y.Z.zip`. Keep the `postflight_steps` block that removes quarantine.
5. Verify like a new user, without touching `/Applications/BrowserBro.app`:
   - `curl -sIL https://github.com/sergchil/browserbro/releases/latest/download/BrowserBro.zip` → 200.
   - `BROWSERBRO_INSTALL_DIR=$(mktemp -d) BROWSERBRO_NO_OPEN=1 bash scripts/install.sh` → installed, no `com.apple.quarantine`.
   - `brew install --cask sergchil/tap/browserbro --appdir=$(mktemp -d)`, then uninstall and untap. Uninstall quits the running app: relaunch `/Applications/BrowserBro.app` after.

## Pitfalls

- The workflow uses `gh release create`, so re-pushing an existing tag fails the run; it never overwrites assets. Rebuilt assets change the ZIP sha256 → the cask must be bumped again.
- GitHub sometimes can't get a hosted runner (job "cancelled"). Re-run with `gh run rerun <id>` or `gh workflow run pages.yml`.
- Not notarized (no paid Apple account). DMG users need System Settings → Privacy & Security → **Open Anyway** once. Homebrew and `install.sh` have no prompt. Don't "fix" this with paid signing.
- Push with the personal `sergchil` account; commits use the Gmail address. Never force-push `main`.
