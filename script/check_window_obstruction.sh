#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dualdock-obstruction-checks.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 5 -O \
  "$ROOT_DIR/Sources/DualDock/WindowObstructionService.swift" \
  "$ROOT_DIR/Tests/WindowObstructionServiceChecks.swift" \
  -module-cache-path "$CHECK_DIR/module-cache" -o "$CHECK_DIR/WindowObstructionServiceChecks"
"$CHECK_DIR/WindowObstructionServiceChecks"
