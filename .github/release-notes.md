BrowserBro __VERSION__ for macOS 26 (Tahoe) or later, Apple silicon.

## Install

**Homebrew** (no security prompt):

```bash
brew install --cask sergchil/tap/browserbro
```

**One line in Terminal** (no security prompt):

```bash
curl -fsSL https://raw.githubusercontent.com/sergchil/browserbro/main/scripts/install.sh | bash
```

**Download**: `BrowserBro.zip` below. Unzip it and drag BrowserBro to Applications. The first time you open it:

1. macOS says it cannot verify BrowserBro. Click **Done** (not "Move to Trash").
2. Open **System Settings → Privacy & Security**, scroll down to **Security**, and click **Open Anyway**. The button stays for about one hour.
3. Enter your Mac password, then click **Open**.

Or skip those steps with: `xattr -dr com.apple.quarantine /Applications/BrowserBro.app`

BrowserBro is not notarized, because notarization costs $99/year. The code is open, so you can build it yourself: https://github.com/sergchil/browserbro#build-from-source

## Files

- `BrowserBro.zip`: the app (recommended download). `BrowserBro.dmg`: the same app as a disk image.
- `BrowserBro-__VERSION__.zip` / `.dmg`: the same files with the version in the name.
- `*.sha256`: SHA-256 checksums.
