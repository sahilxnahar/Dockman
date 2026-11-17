#!/usr/bin/env bash
# Wrap a built Dockman executable into a faceless agent .app bundle (LSUIElement)
# and ad-hoc sign it so it runs as an agent on this machine.
#
# Usage: ./scripts/make-app.sh [target] [config]
#   target: app   (default) -> dockman        -> Dockman.app
#           spike           -> dockman-spike  -> Dockman-Spike.app
#   config: release (default) | debug
set -euo pipefail

TARGET="${1:-app}"
CONFIG="${2:-release}"

case "$TARGET" in
  app)   EXEC="dockman";       APP_NAME="Dockman";       BUNDLE_ID="xyz.waqas.dockman";       DISPLAY="Dockman" ;;
  spike) EXEC="dockman-spike"; APP_NAME="Dockman-Spike"; BUNDLE_ID="xyz.waqas.dockman-spike"; DISPLAY="Dockman (Spike)" ;;
  *) echo "target must be 'app' or 'spike'"; exit 1 ;;
esac

case "$CONFIG" in
  debug)   BUILD_FLAGS="" ;;
  release) BUILD_FLAGS="-c release" ;;
  *) echo "config must be 'debug' or 'release'"; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="build/${APP_NAME}.app"

echo "▶ Building $EXEC ($CONFIG)…"
swift build $BUILD_FLAGS --product "$EXEC"

BIN_PATH="$(swift build $BUILD_FLAGS --show-bin-path)/${EXEC}"
[ -x "$BIN_PATH" ] || { echo "binary not found at $BIN_PATH"; exit 1; }

echo "▶ Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/${EXEC}"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>     <string>${DISPLAY}</string>
  <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key>      <string>${EXEC}</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>0.1.0</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <!-- Faceless agent: no system-Dock icon, no app menu. -->
  <key>LSUIElement</key>             <true/>
  <key>NSHighResolutionCapable</key> <true/>
  <!-- Next Event widget (EventKit). macOS shows this text when asking for access. -->
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Dockman shows your next calendar event in the Next Event widget.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>     <string>${BUNDLE_ID}</string>
      <key>CFBundleURLSchemes</key>  <array><string>dockman</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST


# A stable local identity keeps macOS privacy permissions (Accessibility etc.) across
# rebuilds; ad-hoc signatures change every build, so macOS re-prompts each time.
SIGN_ID="-"
if security find-identity -p codesigning 2>/dev/null | grep -q "Dockman Local Signing"; then
  SIGN_ID="Dockman Local Signing"
fi
echo "▶ Signing with: $SIGN_ID"
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP" || true

echo "✅ Built $APP"
echo "   Run:  open \"$APP\""
echo "   Quit: killall ${EXEC}    (or use the menu-bar item ▸ Quit)"
