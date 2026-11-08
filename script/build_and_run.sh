#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
case "$MODE" in
  run|--build-only|--verify|--logs|--telemetry|--debug) ;;
  *) echo "usage: $0 [run|--build-only|--verify|--logs|--telemetry|--debug]" >&2; exit 2 ;;
esac

if pgrep -x DualDock >/dev/null; then
  pkill -TERM -x DualDock
  for attempt in {1..40}; do
    if ! pgrep -x DualDock >/dev/null; then break; fi
    sleep 0.25
  done
  if pgrep -x DualDock >/dev/null; then
    echo "DualDock is still open. Complete its system Dock restoration dialog, then retry." >&2
    exit 1
  fi
fi

swift build
BIN_DIR="$(swift build --show-bin-path)"
APP_BUNDLE="$ROOT_DIR/dist/DualDock.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_DIR/DualDock" "$APP_BUNDLE/Contents/MacOS/DualDock"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
if [ ! -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
  xcrun swift "$ROOT_DIR/script/make_icon.swift" "$ROOT_DIR/Resources"
  iconutil -c icns "$ROOT_DIR/Resources/AppIcon.iconset" -o "$ROOT_DIR/Resources/AppIcon.icns"
fi
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier local.ronny.DualDock \
  --requirements '=designated => identifier "local.ronny.DualDock"' "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE"
echo "Built $APP_BUNDLE"

case "$MODE" in
  --build-only) exit 0 ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/DualDock" ;;
  --logs|--telemetry)
    open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'process == "DualDock"'
    ;;
  --verify)
    open -n "$APP_BUNDLE"
    sleep 2
    pgrep -x DualDock >/dev/null
    echo "DualDock process is running."
    ;;
  run) open -n "$APP_BUNDLE" ;;
esac
