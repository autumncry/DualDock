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

APP_BUNDLE="$("$ROOT_DIR/script/package_app.sh" debug)"
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
