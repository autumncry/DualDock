#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dualdock-window-backend-queue.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 5 -O -emit-module -emit-library -module-name DualDockCore \
  "$ROOT_DIR"/Sources/DualDockCore/*.swift \
  -emit-module-path "$CHECK_DIR/DualDockCore.swiftmodule" \
  -module-cache-path "$CHECK_DIR/module-cache" -o "$CHECK_DIR/libDualDockCore.dylib"
xcrun swiftc -swift-version 5 -O \
  "$ROOT_DIR/Sources/DualDock/AppLanguage.swift" "$ROOT_DIR/Sources/DualDock/WindowInteractionService.swift" \
  "$ROOT_DIR/Sources/DualDock/WindowInteractionBackend.swift" \
  "$ROOT_DIR/Sources/DualDock/ApplicationActivationService.swift" \
  "$ROOT_DIR/Sources/DualDock/WindowService.swift" \
  "$ROOT_DIR/Sources/DualDock/FullscreenFallbackService.swift" \
  "$ROOT_DIR/Tests/WindowBackendQueueChecks.swift" \
  -I "$CHECK_DIR" -L "$CHECK_DIR" -lDualDockCore -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  -module-cache-path "$CHECK_DIR/module-cache" -o "$CHECK_DIR/WindowBackendQueueChecks"
"$CHECK_DIR/WindowBackendQueueChecks"
