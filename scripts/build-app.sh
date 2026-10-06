#!/usr/bin/env bash
# Builds BrowserBro.app into ./build with SwiftPM, then ad-hoc signs it.
# No paid Apple Developer membership needed.
#
#   scripts/build-app.sh            # release build → build/BrowserBro.app
#   scripts/build-app.sh --install  # also copy to /Applications (quits a running copy first)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-1.2.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="build/BrowserBro.app"

# Universal binary: Apple silicon and Intel.
ARCHS=(--arch arm64 --arch x86_64)

echo "→ swift build (release, universal)"
swift build -c release --product BrowserBro "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/BrowserBro"

echo "→ assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BrowserBro"
# SwiftPM records the SDK version as the deployment target (14.0). macOS 26 reads the linked SDK
# version to choose the Liquid Glass look for system controls, so stamp the real SDK version.
vtool -set-build-version macos 14.0 "$(xcrun --show-sdk-version)" -replace \
  -output "$APP/Contents/MacOS/BrowserBro" "$APP/Contents/MacOS/BrowserBro" 2>/dev/null
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "→ icon"
ICONSET="build/AppIcon.iconset"
if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ]; then
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  swift scripts/make-icon.swift build/AppIcon-1024.png >/dev/null
  for s in 16 32 128 256 512; do
    sips -z $s $s build/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "→ ad-hoc sign"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

if [ "${1:-}" = "--install" ]; then
  echo "→ install to /Applications"
  osascript -e 'tell application id "com.sergchil.BrowserBro" to quit' >/dev/null 2>&1 || true
  pkill -x BrowserBro 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/BrowserBro.app
  cp -R "$APP" /Applications/BrowserBro.app
  # Register with Launch Services so it appears in System Settings → Default web browser.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/BrowserBro.app
  echo "Installed /Applications/BrowserBro.app"
fi
echo "Done: $APP"
