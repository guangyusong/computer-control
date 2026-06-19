#!/bin/bash
set -euo pipefail

APP_NAME="ComputerControl"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
APP_ICON="$APP_BUNDLE/Contents/Resources/AppIcon.icns"

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ -d "$APP_BUNDLE" ]] || fail "missing app bundle at $APP_BUNDLE"
[[ -f "$INFO_PLIST" ]] || fail "missing Info.plist"
[[ -x "$APP_BINARY" ]] || fail "missing executable $APP_BINARY"
[[ -f "$APP_ICON" ]] || fail "missing AppIcon.icns"

ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$ICON_NAME" == "AppIcon" ]] || fail "CFBundleIconFile should be AppIcon, got '${ICON_NAME:-missing}'"

echo "Bundle: $APP_BUNDLE"
echo "Executable: $APP_BINARY"
echo "Icon: $APP_ICON"
echo

echo "codesign:"
codesign -dvvv --entitlements :- "$APP_BUNDLE" 2>&1 || fail "codesign inspection failed"
echo

echo "Gatekeeper:"
if spctl -a -vv "$APP_BUNDLE" 2>&1; then
  echo "Gatekeeper accepted this artifact."
else
  echo "Gatekeeper rejected this artifact. This is expected for local Apple Development builds; use Developer ID plus notarization for public binary distribution."
fi
