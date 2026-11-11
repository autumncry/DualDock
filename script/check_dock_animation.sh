#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dualdock-animation-checks.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 5 -O -emit-module -emit-library -module-name DualDockCore \
  "$ROOT_DIR"/Sources/DualDockCore/*.swift \
  -emit-module-path "$CHECK_DIR/DualDockCore.swiftmodule" \
  -module-cache-path "$CHECK_DIR/module-cache" -o "$CHECK_DIR/libDualDockCore.dylib"
xcrun swiftc -swift-version 5 -O \
  "$ROOT_DIR/Sources/DualDock/DockUI.swift" "$ROOT_DIR/Sources/DualDock/DockTile.swift" \
  "$ROOT_DIR/Sources/DualDock/DockResizeCursor.swift" \
  "$ROOT_DIR/Sources/DualDock/DockDisplayInfo.swift" "$ROOT_DIR/Sources/DualDock/DockPresentation.swift" \
  "$ROOT_DIR/Sources/DualDock/NativeDockMetricsService.swift" \
  "$ROOT_DIR/Sources/DualDock/AppStore.swift" "$ROOT_DIR/Sources/DualDock/ApplicationActivationService.swift" \
  "$ROOT_DIR/Sources/DualDock/WindowService.swift" "$ROOT_DIR/Sources/DualDock/FullscreenFallbackService.swift" \
  "$ROOT_DIR/Sources/DualDock/SystemDockService.swift" "$ROOT_DIR/Sources/DualDock/DockBadgeService.swift" \
  "$ROOT_DIR/Tests/DockAnimationViewChecks.swift" \
  -I "$CHECK_DIR" -L "$CHECK_DIR" -lDualDockCore -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  -module-cache-path "$CHECK_DIR/module-cache" -o "$CHECK_DIR/DockAnimationViewChecks"
"$CHECK_DIR/DockAnimationViewChecks" "$CHECK_DIR/configuration"
