#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dualdock-fullscreen-checks.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 5 -O \
  "$ROOT_DIR/Sources/DualDock/FullscreenFallbackService.swift" \
  "$ROOT_DIR/Tests/FullscreenFallbackServiceChecks.swift" \
  -module-cache-path "$CHECK_DIR/module-cache" -o "$CHECK_DIR/FullscreenFallbackServiceChecks"
"$CHECK_DIR/FullscreenFallbackServiceChecks"
