#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
INFO="$DIST/release/DualDock 3.app/Contents/Info.plist"
SPARKLE_DIST="$("$ROOT/script/sparkle_tools.sh")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
ARCH="$(lipo -archs "$DIST/release/DualDock 3.app/Contents/MacOS/DualDock3")"
NAME="DualDock-$VERSION-$ARCH.dmg"
UPDATE_DIR="$(mktemp -d "$DIST/.dualdock-appcast.XXXXXX")"
trap 'rm -rf "$UPDATE_DIR"' EXIT
(cd "$DIST" && shasum -a 256 -c "$NAME.sha256" >&2)
ln "$DIST/$NAME" "$UPDATE_DIR/$NAME"
cp "$ROOT/docs/release-notes/v$VERSION.md" "$UPDATE_DIR/${NAME%.dmg}.md"
# Only this immutable release is offered. Never publish or overwrite the live
# feed before the tag's official assets have been made public and verified.
"$SPARKLE_DIST/bin/generate_appcast" --account DualDock --maximum-deltas 0 --embed-release-notes \
  --download-url-prefix "https://github.com/autumncry/DualDock/releases/download/v$VERSION/" \
  --link "https://github.com/autumncry/DualDock" \
  --full-release-notes-url "https://github.com/autumncry/DualDock/releases/tag/v$VERSION" \
  -o "$UPDATE_DIR/appcast.xml" "$UPDATE_DIR" >&2
xcrun swift "$ROOT/script/verify_appcast.swift" "$INFO" "$UPDATE_DIR/appcast.xml" "$DIST/$NAME" >&2
mkdir -p "$DIST/updates/3"
mv "$UPDATE_DIR/appcast.xml" "$DIST/updates/3/appcast.xml"
echo "$DIST/updates/3/appcast.xml"
