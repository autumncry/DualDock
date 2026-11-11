#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dualdock-native-metrics-checks.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

xcrun swiftc -swift-version 5 -O -emit-module -emit-library -module-name DualDockCore \
  "$ROOT_DIR/Sources/DualDockCore/NativeDockMetrics.swift" \
  -emit-module-path "$CHECK_DIR/DualDockCore.swiftmodule" \
  -module-cache-path "$CHECK_DIR/module-cache" -o "$CHECK_DIR/libDualDockCore.dylib"

xcrun swiftc -swift-version 5 -O \
  "$ROOT_DIR/Sources/DualDock/NativeDockMetricsService.swift" \
  "$ROOT_DIR/Tests/NativeDockMetricsServiceChecks.swift" \
  -I "$CHECK_DIR" -L "$CHECK_DIR" -lDualDockCore -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  -module-cache-path "$CHECK_DIR/module-cache" -o "$CHECK_DIR/NativeDockMetricsServiceChecks"
"$CHECK_DIR/NativeDockMetricsServiceChecks"
