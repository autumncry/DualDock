#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAPTURE_DIR="${1:-$ROOT_DIR/.impeccable/review/settings}"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dualdock-settings-render.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 5 -O -emit-module -emit-library -module-name DualDockCore \
  "$ROOT_DIR"/Sources/DualDockCore/*.swift -emit-module-path "$CHECK_DIR/DualDockCore.swiftmodule" \
  -module-cache-path "$CHECK_DIR/module-cache" -o "$CHECK_DIR/libDualDockCore.dylib"
SOURCES=()
for SOURCE in "$ROOT_DIR"/Sources/DualDock/*.swift; do
  if [[ "$SOURCE" != */DualDockApp.swift ]]; then SOURCES+=("$SOURCE"); fi
done
xcrun swiftc -swift-version 5 -O "${SOURCES[@]}" "$ROOT_DIR/script/render_settings.swift" \
  -I "$CHECK_DIR" -L "$CHECK_DIR" -lDualDockCore -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  -module-cache-path "$CHECK_DIR/module-cache" -o "$CHECK_DIR/RenderSettings"
"$CHECK_DIR/RenderSettings" "$ROOT_DIR" "$CAPTURE_DIR" "${2:-}"
