#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dualdock-optical-view-checks.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
# Keep one coherent source snapshot while other independent checks are running.
cp -R "$ROOT_DIR/Sources" "$CHECK_DIR/Sources"
cp "$ROOT_DIR/Tests/OpticalDockViewChecks.swift" "$CHECK_DIR/OpticalDockViewChecks.swift"

xcrun swiftc -swift-version 5 -O -emit-module -emit-library -module-name DualDockCore \
  "$CHECK_DIR"/Sources/DualDockCore/*.swift \
  -emit-module-path "$CHECK_DIR/DualDockCore.swiftmodule" \
  -module-cache-path "$CHECK_DIR/module-cache" -o "$CHECK_DIR/libDualDockCore.dylib"

xcrun swiftc -swift-version 5 -O \
  "$CHECK_DIR/Sources/DualDock/DockUI.swift" "$CHECK_DIR/Sources/DualDock/DockTile.swift" \
  "$CHECK_DIR/Sources/DualDock/DockResizeCursor.swift" \
  "$CHECK_DIR/Sources/DualDock/DockDisplayInfo.swift" "$CHECK_DIR/Sources/DualDock/DockPresentation.swift" \
  "$CHECK_DIR/Sources/DualDock/NativeDockMetricsService.swift" \
  "$CHECK_DIR/Sources/DualDock/IconArtworkBounds.swift" "$CHECK_DIR/Sources/DualDock/AppStore.swift" "$CHECK_DIR/Sources/DualDock/WindowService.swift" \
  "$CHECK_DIR/Sources/DualDock/FullscreenFallbackService.swift" "$CHECK_DIR/Sources/DualDock/ApplicationActivationService.swift" \
  "$CHECK_DIR/Sources/DualDock/SystemDockService.swift" "$CHECK_DIR/Sources/DualDock/DockBadgeService.swift" \
  "$CHECK_DIR/OpticalDockViewChecks.swift" \
  -I "$CHECK_DIR" -L "$CHECK_DIR" -lDualDockCore -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  -module-cache-path "$CHECK_DIR/module-cache" -o "$CHECK_DIR/OpticalDockViewChecks"
"$CHECK_DIR/OpticalDockViewChecks" "$CHECK_DIR" "${1:-}"
