#!/bin/bash
# Builds MyGitApp and assembles build/MyGitApp.app (ad-hoc signed).
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/MyGitApp.app"
cd "$ROOT"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/MyGitApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MyGitApp"

# App icon: assets/AppIcon.icns is committed (CI runners can't render SVG with Quick Look).
# Regenerate it from assets/icon.svg with `make icon`.
ICNS="$ROOT/assets/AppIcon.icns"
if [[ ! -f "$ICNS" ]]; then
  TMP="$(mktemp -d)"
  qlmanage -t -s 1024 -o "$TMP" "$ROOT/assets/icon.svg" >/dev/null 2>&1 || true
  if [[ -f "$TMP/icon.svg.png" ]]; then
    ICONSET="$TMP/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
      sips -z $size $size "$TMP/icon.svg.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
      sips -z $((size * 2)) $((size * 2)) "$TMP/icon.svg.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ICNS"
  fi
  rm -rf "$TMP"
fi
[[ -f "$ICNS" ]] && cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# Version: APP_VERSION / APP_BUILD from CI, otherwise VERSION + ".0" for local builds.
APP_VERSION="${APP_VERSION:-$(cat "$ROOT/VERSION").0}"
APP_BUILD="${APP_BUILD:-1}"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MyGitApp</string>
  <key>CFBundleDisplayName</key><string>MyGitApp</string>
  <key>CFBundleIdentifier</key><string>com.slaynn.mygitapp</string>
  <key>CFBundleExecutable</key><string>MyGitApp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($APP_VERSION)"
