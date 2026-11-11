#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dualdock-system-checks.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

# Keep both compilation and test fixtures outside SwiftPM's build directory.
# The driver always injects an in-memory environment; it never changes the Dock.
xcrun swiftc -swift-version 5 -Onone \
    -emit-module -emit-library -module-name DualDockCore \
    "$ROOT_DIR"/Sources/DualDockCore/*.swift \
    -emit-module-path "$CHECK_DIR/DualDockCore.swiftmodule" \
    -module-cache-path "$CHECK_DIR/module-cache" \
    -o "$CHECK_DIR/libDualDockCore.dylib"

xcrun swiftc -swift-version 5 -Onone \
    "$ROOT_DIR/Sources/DualDock/SystemDockService.swift" \
    "$ROOT_DIR/Tests/SystemDockChecks.swift" \
    -I "$CHECK_DIR" -L "$CHECK_DIR" -lDualDockCore \
    -Xlinker -rpath -Xlinker "$CHECK_DIR" \
    -module-cache-path "$CHECK_DIR/module-cache" \
    -o "$CHECK_DIR/SystemDockChecks"

"$CHECK_DIR/SystemDockChecks" "$CHECK_DIR"
