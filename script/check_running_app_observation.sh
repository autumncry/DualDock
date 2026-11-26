#!/usr/bin/env bash
# A windowless LSUIElement switches activation policy without receiving focus.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dualdock-policy-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 5 -O -emit-module -emit-library -module-name DualDockCore \
  "$ROOT"/Sources/DualDockCore/*.swift -emit-module-path "$CHECK_DIR/DualDockCore.swiftmodule" \
  -module-cache-path "$CHECK_DIR/modules" -o "$CHECK_DIR/libDualDockCore.dylib"
SOURCES=()
for name in AppLanguage DockDisplayInfo DockPresentation NativeDockMetricsService IconArtworkBounds AppStore WindowService FullscreenFallbackService ApplicationActivationService SystemDockService DockBadgeService; do
  SOURCES+=("$ROOT/Sources/DualDock/$name.swift")
done
xcrun swiftc -swift-version 5 -O "${SOURCES[@]}" "$ROOT/Tests/RunningAppObservationChecks.swift" \
  -I "$CHECK_DIR" -L "$CHECK_DIR" -lDualDockCore -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  -module-cache-path "$CHECK_DIR/modules" -o "$CHECK_DIR/ObservationChecks"
FIXTURE="$CHECK_DIR/Policy Fixture.app"
mkdir -p "$FIXTURE/Contents/MacOS"
cp "$CHECK_DIR/ObservationChecks" "$FIXTURE/Contents/MacOS/PolicyFixture"
python3 - "$FIXTURE/Contents/Info.plist" <<'PY'
import plistlib, sys, uuid
with open(sys.argv[1], "wb") as f:
    plistlib.dump(dict(CFBundleName="DualDock Policy Fixture", CFBundleExecutable="PolicyFixture",
                       CFBundleIdentifier="local.dualdock.qa.policy." + uuid.uuid4().hex,
                       CFBundlePackageType="APPL", CFBundleVersion="1", LSUIElement=True), f)
PY
codesign --force --sign - "$FIXTURE"
"$CHECK_DIR/ObservationChecks" "$FIXTURE" "$CHECK_DIR/configuration"
