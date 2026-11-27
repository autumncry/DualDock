#!/usr/bin/env bash
set -euo pipefail

mode="${1:-run}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

case "$mode" in
  --build-only) exec "$root/script/package_app.sh" debug ;;
  --preview)
    name=DualDockDev
    destination="$root/dist/preview/DualDock.app"
    builder="$root/script/package_preview.sh"
    ;;
  run|--release-dev|--verify|--logs|--telemetry|--debug)
    name=DualDock
    destination="$root/dist/DualDock.app"
    builder="$root/script/package_app.sh"
    ;;
  *) echo "usage: $0 [run|--preview|--build-only|--release-dev|--verify|--logs|--telemetry|--debug]" >&2; exit 2 ;;
esac

# A bundle elsewhere may be the installed release or another developer's checkout.
# Inspect every candidate before stopping any process.
pids="$(pgrep -x "$name" || true)"
for pid in $pids; do
  process="$(ps -p "$pid" -o comm= || true)"
  if [ -n "$process" ] && [ "$process" != "$destination/Contents/MacOS/$name" ]; then
    echo "A different $name is running. Use --preview to run alongside the installed release." >&2
    exit 1
  fi
done
app="$("$builder" debug)"
for pid in $pids; do
  if [ "$(ps -p "$pid" -o comm= || true)" = "$app/Contents/MacOS/$name" ]; then kill -TERM "$pid"; fi
done
for attempt in {1..40}; do
  if ! pgrep -x "$name" >/dev/null; then break; fi
  sleep 0.25
done
if pgrep -x "$name" >/dev/null; then
  echo "$name is still open. Finish quitting it before reopening." >&2; exit 1
fi

case "$mode" in
  --debug) exec lldb -- "$app/Contents/MacOS/$name" ;;
  --logs|--telemetry)
    open "$app"
    /usr/bin/log stream --info --style compact --predicate 'process == "DualDock"'
    ;;
  --verify)
    open "$app"; sleep 2
    pgrep -x "$name" >/dev/null
    echo "$name is running."
    ;;
  *) open "$app" ;;
esac
