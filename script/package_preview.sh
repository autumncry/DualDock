#!/usr/bin/env bash
# Package only the local preview. No downloads, online update feed or writes to /Applications.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"
case "$configuration" in release|debug) ;; *) echo 'Use release or debug.' >&2; exit 2 ;; esac
cd "$root"
# Compile the same sources as the release target without the SwiftPM-only updater.
mkdir -p "$root/.build"
stage="$(mktemp -d "$root/.build/local-preview.XXXXXX")"
app="$stage/DualDock 3.app"
destination="$root/DualDock 3.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
flags=(-swift-version 5 -target "$(uname -m)-apple-macosx14.0")
if [ "$configuration" = release ]; then flags+=(-O -whole-module-optimization); else flags+=(-Onone -g); fi
xcrun swiftc "${flags[@]}" -parse-as-library -emit-module -emit-library -static -module-name DualDockCore \
    Sources/DualDockCore/*.swift -emit-module-path "$stage/DualDockCore.swiftmodule" -o "$stage/libDualDockCore.a"
xcrun swiftc "${flags[@]}" -parse-as-library -module-name DualDock -I "$stage" -L "$stage" -lDualDockCore \
    Sources/DualDock/*.swift -o "$app/Contents/MacOS/DualDockPreview"
python3 - "$root/Resources/Info.plist" "$app/Contents/Info.plist" <<'PYTHON'
import plistlib, sys
from pathlib import Path
info = plistlib.loads(Path(sys.argv[1]).read_bytes())
for key in list(info):
    if key.startswith("SU"):
        del info[key]
info.update(CFBundleName="DualDock 3", CFBundleDisplayName="DualDock 3",
            CFBundleExecutable="DualDockPreview", CFBundleIdentifier="local.ronny.DualDock3Preview")
Path(sys.argv[2]).write_bytes(plistlib.dumps(info, sort_keys=False))
PYTHON
cp "$root/Resources/AppIcon.icns" "$root/LICENSE" "$app/Contents/Resources"
for language in "$root"/Resources/*.lproj; do ditto "$language" "$app/Contents/Resources/$(basename "$language")"; done
codesign --force --sign - --identifier local.ronny.DualDock3Preview \
  --requirements '=designated => identifier "local.ronny.DualDock3Preview"' "$app" >&2
codesign --verify --deep --strict "$app" >&2
if [ -e "$destination" ]; then
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")" = local.ronny.DualDock3Preview ] || exit 1
  mv "$destination" "$stage/previous.app"
fi
if ! mv "$app" "$destination"; then
  if [ -e "$stage/previous.app" ]; then mv "$stage/previous.app" "$destination"; fi
  exit 1
fi
rm -rf "$stage"
echo "$destination"
