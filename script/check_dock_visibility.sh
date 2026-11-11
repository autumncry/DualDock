#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dualdock-visibility-checks.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

xcrun swiftc -swift-version 5 -O -emit-module -emit-library -module-name DualDockCore \
  "$ROOT_DIR"/Sources/DualDockCore/*.swift \
  -emit-module-path "$CHECK_DIR/DualDockCore.swiftmodule" \
  -module-cache-path "$CHECK_DIR/module-cache" -o "$CHECK_DIR/libDualDockCore.dylib"

# The fixture supplies only fullscreen state; the controller and disabled
# obstruction service are production code, with no test-only source rewrites.
xcrun swiftc -swift-version 5 -O \
  "$ROOT_DIR/Sources/DualDock/DockVisibilityController.swift" \
  "$ROOT_DIR/Sources/DualDock/WindowObstructionService.swift" \
  "$ROOT_DIR/Tests/DockVisibilityControllerChecks.swift" \
  -I "$CHECK_DIR" -L "$CHECK_DIR" -lDualDockCore -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  -module-cache-path "$CHECK_DIR/module-cache" -o "$CHECK_DIR/DockVisibilityControllerChecks"
"$CHECK_DIR/DockVisibilityControllerChecks"
