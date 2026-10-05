#!/usr/bin/env bash
# Builds BrowserBro.app and packs it for release:
#   build/BrowserBro-<version>.zip  (+ .sha256)   main download, used by install.sh and Homebrew
#   build/BrowserBro-<version>.dmg  (+ .sha256)   drag-to-Applications disk image
#   build/BrowserBro.zip / build/BrowserBro.dmg  (+ .sha256)  stable names for releases/latest/download/…
#
#   VERSION=1.0.0 scripts/make-dmg.sh
#   SKIP_BUILD=1 VERSION=1.0.0 scripts/make-dmg.sh   # reuse build/BrowserBro.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-1.0.0}"
export VERSION
APP="build/BrowserBro.app"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  scripts/build-app.sh
fi
[ -d "$APP" ] || { echo "error: $APP not found" >&2; exit 1; }

# The packed app must carry the version we are releasing.
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [ "$APP_VERSION" != "$VERSION" ]; then
  echo "error: $APP has version $APP_VERSION, expected $VERSION" >&2
  exit 1
fi
codesign --verify --strict "$APP"

ZIP="build/BrowserBro-$VERSION.zip"
DMG="build/BrowserBro-$VERSION.dmg"

checksum() { # writes "<sha256>  <file name>" next to the file
  (cd "$(dirname "$1")" && shasum -a 256 "$(basename "$1")" > "$(basename "$1").sha256")
}

echo "→ zip $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "→ dmg $DMG"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/browserbro-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/BrowserBro.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "BrowserBro" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
hdiutil verify -quiet "$DMG"

echo "→ stable names + checksums"
cp -f "$ZIP" build/BrowserBro.zip
cp -f "$DMG" build/BrowserBro.dmg
for f in "$ZIP" "$DMG" build/BrowserBro.zip build/BrowserBro.dmg; do checksum "$f"; done

ls -l "$ZIP" "$DMG" build/BrowserBro.zip build/BrowserBro.dmg
cat build/*.sha256
