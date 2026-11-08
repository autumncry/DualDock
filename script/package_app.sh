#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
case "$CONFIGURATION" in
  debug) APP_BUNDLE="$ROOT_DIR/dist/DualDock.app" ;;
  release) APP_BUNDLE="$ROOT_DIR/dist/release/DualDock.app" ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac
cd "$ROOT_DIR"

swift build -c "$CONFIGURATION" >&2
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
STAGING_DIR="$(mktemp -d "$ROOT_DIR/.build/dualdock-package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/DualDock.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_DIR/DualDock" "$STAGED_APP/Contents/MacOS/DualDock"
cp "$ROOT_DIR/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$ROOT_DIR/LICENSE" "$STAGED_APP/Contents/Resources/LICENSE.txt"
if [ ! -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
  xcrun swift "$ROOT_DIR/script/make_icon.swift" "$ROOT_DIR/Resources" >&2
  iconutil -c icns "$ROOT_DIR/Resources/AppIcon.iconset" -o "$ROOT_DIR/Resources/AppIcon.icns" >&2
fi
cp "$ROOT_DIR/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier local.ronny.DualDock \
  --requirements '=designated => identifier "local.ronny.DualDock"' "$STAGED_APP" >&2
codesign --verify --strict "$STAGED_APP" >&2
mkdir -p "$(dirname "$APP_BUNDLE")"
rm -rf "$APP_BUNDLE"
mv "$STAGED_APP" "$APP_BUNDLE"
echo "$APP_BUNDLE"
