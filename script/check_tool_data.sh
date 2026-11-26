#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/.build/tool-data-checks"
TEST_DIR="$(mktemp -d "$ROOT/.build/tool-data-checks/run.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$ROOT"
xcrun swiftc -swift-version 5 -O -module-cache-path "$ROOT/.build/tool-data-checks/modules" \
    Sources/DualDock/AppLanguage.swift Sources/DualDock/ToolData*.swift Tests/ToolDataProviderChecks.swift \
    -o "$TEST_DIR/ToolDataProviderChecks"
"$TEST_DIR/ToolDataProviderChecks" "$TEST_DIR/config"
