#!/usr/bin/env bash
# Installs the latest BrowserBro release.
#
#   curl -fsSL https://raw.githubusercontent.com/sergchil/browserbro/main/scripts/install.sh | bash
#
# What it does: downloads BrowserBro.zip from GitHub Releases, checks its SHA-256,
# quits a running copy at the same place, installs to /Applications (or ~/Applications
# when /Applications is not writable), removes the quarantine flag, registers the app
# with macOS and opens it. Safe to run again: it updates in place.
#
# Options (environment variables):
#   BROWSERBRO_VERSION=1.0.0       install this version instead of the latest
#   BROWSERBRO_INSTALL_DIR=<dir>   install into <dir> instead of /Applications
#   BROWSERBRO_NO_OPEN=1           do not open the app at the end
set -euo pipefail

REPO="sergchil/browserbro"
APP_NAME="BrowserBro.app"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Everything runs inside main, so a cut-off download (curl | bash) runs nothing.
main() {
# 1. This Mac
[ "$(uname -s)" = "Darwin" ] || fail "BrowserBro runs on macOS only."
MACOS="$(sw_vers -productVersion)"
[ "${MACOS%%.*}" -ge 14 ] 2>/dev/null || fail "BrowserBro needs macOS 14 (Sonoma) or later. This Mac has macOS $MACOS."
# The app is a universal binary: Apple silicon and Intel.

# 2. Where to install
if [ -n "${BROWSERBRO_INSTALL_DIR:-}" ]; then
  DEST_DIR="$BROWSERBRO_INSTALL_DIR"
  mkdir -p "$DEST_DIR"
elif [ -w /Applications ] && { [ ! -e "/Applications/$APP_NAME" ] || [ -w "/Applications/$APP_NAME" ]; }; then
  DEST_DIR="/Applications"
else
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
  say "/Applications is not writable, so BrowserBro goes to $DEST_DIR"
fi
[ -w "$DEST_DIR" ] || fail "Cannot write to $DEST_DIR."
DEST="$(cd "$DEST_DIR" && pwd)/$APP_NAME"

# 3. Download and check
if [ -n "${BROWSERBRO_VERSION:-}" ]; then
  BASE="https://github.com/$REPO/releases/download/v${BROWSERBRO_VERSION#v}"
else
  BASE="https://github.com/$REPO/releases/latest/download"
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/browserbro-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

say "Downloading BrowserBro…"
curl -fsSL --retry 3 -o "$WORK/BrowserBro.zip" "$BASE/BrowserBro.zip" || fail "Download failed: $BASE/BrowserBro.zip"
curl -fsSL --retry 3 -o "$WORK/BrowserBro.zip.sha256" "$BASE/BrowserBro.zip.sha256" || fail "Download failed: $BASE/BrowserBro.zip.sha256"

EXPECTED="$(awk '{print $1; exit}' "$WORK/BrowserBro.zip.sha256")"
ACTUAL="$(shasum -a 256 "$WORK/BrowserBro.zip" | awk '{print $1}')"
[ -n "$EXPECTED" ] && [ "$EXPECTED" = "$ACTUAL" ] || fail "Checksum mismatch (expected $EXPECTED, got $ACTUAL). Nothing was installed."
say "Checksum OK ($ACTUAL)"

ditto -x -k "$WORK/BrowserBro.zip" "$WORK/unzipped"
[ -d "$WORK/unzipped/$APP_NAME" ] || fail "The download does not contain $APP_NAME."
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$WORK/unzipped/$APP_NAME/Contents/Info.plist" 2>/dev/null || echo '?')"

# 4. Quit a running copy of the app we are about to replace (only that copy).
BIN="$DEST/Contents/MacOS/BrowserBro"
running_pids() { pgrep -x BrowserBro 2>/dev/null | while read -r p; do [ "$(ps -o comm= -p "$p" 2>/dev/null)" = "$BIN" ] && echo "$p"; done; true; }
PIDS="$(running_pids)"
if [ -n "$PIDS" ]; then
  say "Quitting the running BrowserBro…"
  kill $PIDS 2>/dev/null || true
  for _ in $(seq 1 50); do [ -z "$(running_pids)" ] && break; sleep 0.1; done
  PIDS="$(running_pids)"
  [ -z "$PIDS" ] || kill -9 $PIDS 2>/dev/null || true
fi

# 5. Install (replace in place)
say "Installing BrowserBro $VERSION to $DEST"
rm -rf "$DEST"
ditto "$WORK/unzipped/$APP_NAME" "$DEST"
# curl downloads are not quarantined, but remove the flag anyway so Gatekeeper never blocks the first launch.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
# Register with Launch Services so BrowserBro shows up as a possible default web browser.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true

# 6. Open
if [ "${BROWSERBRO_NO_OPEN:-0}" != "1" ]; then
  say "Opening BrowserBro…"
  open "$DEST"
fi
say "Done. BrowserBro $VERSION is installed at $DEST"
echo "    Next: in BrowserBro Settings, click \"Set as Default Browser\"."
}

main "$@"
