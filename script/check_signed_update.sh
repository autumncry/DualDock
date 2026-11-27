#!/usr/bin/env bash
# Exercise release verification using public artifacts only. Safe to run after
# make_appcast, on machines without the maintainer's signing key.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO="$ROOT/dist/release/DualDock 3.app/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
ARCH="$(lipo -archs "$ROOT/dist/release/DualDock 3.app/Contents/MacOS/DualDock3")"
NAME="DualDock-$VERSION-$ARCH.dmg"
ARCHIVE="$ROOT/dist/$NAME"
FEED="$ROOT/dist/updates/3/appcast.xml"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dualdock-update-check.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
xcrun swiftc -O "$ROOT/script/verify_appcast.swift" -module-cache-path "$TMP/modules" -o "$TMP/verify"
"$TMP/verify" "$INFO" "$FEED" "$ARCHIVE"

# Replace one byte without changing file lengths. Metadata checks alone would
# pass either corrupt artifact; both must fail the public-key signature check.
python3 - "$FEED" "$ARCHIVE" "$TMP" <<'PY'
from pathlib import Path
import shutil
import sys

feed, archive, out = map(Path, sys.argv[1:])
data = bytearray(feed.read_bytes())
i = data.index(b'<title>') + len(b'<title>')
data[i] = ord('X') if data[i] != ord('X') else ord('Y')
(out / 'appcast.xml').write_bytes(data)
target = out / archive.name
shutil.copyfile(archive, target)
with target.open('r+b') as f:
    offset = target.stat().st_size // 2
    f.seek(offset)
    first = f.read(1)
    f.seek(offset)
    f.write(bytes([first[0] ^ 1]))
PY
if "$TMP/verify" "$INFO" "$TMP/appcast.xml" "$ARCHIVE"; then
  echo "Modified appcast accepted" >&2; exit 1
fi
if "$TMP/verify" "$INFO" "$FEED" "$TMP/$NAME"; then
  echo "Modified DMG accepted" >&2; exit 1
fi
echo "Authentic artifacts accepted; modified feed and modified DMG rejected."
