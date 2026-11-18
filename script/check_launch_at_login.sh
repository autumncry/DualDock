#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dualdock-login-checks.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 5 -O \
  "$ROOT_DIR/Sources/DualDock/AppLanguage.swift" "$ROOT_DIR/Sources/DualDock/LaunchAtLoginService.swift" \
  "$ROOT_DIR/Tests/LaunchAtLoginChecks.swift" \
  -module-cache-path "$CHECK_DIR/module-cache" -o "$CHECK_DIR/LaunchAtLoginChecks"
"$CHECK_DIR/LaunchAtLoginChecks"
