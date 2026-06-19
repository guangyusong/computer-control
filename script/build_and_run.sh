#!/bin/bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="ComputerControl"
BUNDLE_ID="com.guangyusong.ComputerControl"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_FILE="$ROOT_DIR/Sources/ComputerControl/Resources/AppIcon.icns"

if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env"
  set +a
fi

stop_app() {
  while read -r pid; do
    [[ -z "$pid" || "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
    /bin/kill "$pid" >/dev/null 2>&1 || true
  done < <(/usr/bin/pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true)
}

verify_app() {
  /usr/bin/pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null
}

stop_app
swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
if [[ -f "$ICON_FILE" ]]; then
  cp "$ICON_FILE" "$APP_RESOURCES/AppIcon.icns"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>Computer Control</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSQuitAlwaysKeepsWindows</key>
  <false/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Computer Control uses the microphone for voice commands.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Computer Control uses speech recognition to transcribe voice commands.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Computer Control uses screen capture for future visual computer-use loops.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Computer Control uses Apple Events for approved app automation.</string>
</dict>
</plist>
PLIST

SIGNING_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/awk -F '"' '/Apple Development/ { print $2; exit }')"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="-"
fi

/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --identifier "$BUNDLE_ID" "$APP_BUNDLE"

open_app() {
  rm -rf "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    verify_app
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
