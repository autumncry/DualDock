#!/usr/bin/env bash
# Prints the verified release tool directory. With --extract-framework-to,
# unpack the shipping framework and license directly from the pinned archive.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION=2.10.1
DIGEST=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
CACHE="$ROOT/.build/sparkle-tools"
NAME="Sparkle-$VERSION.tar.xz"
ARCHIVE="$CACHE/downloads/$NAME"
BIN="$CACHE/$VERSION"
mkdir -p "$CACHE/downloads"
if [[ ! -f "$ARCHIVE" ]]; then
  TMP="$(mktemp -d "$CACHE/downloads/.fetch.XXXXXX")"
  trap 'rm -rf "$TMP"' EXIT
  curl --fail --location --retry 2 --proto '=https' \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/$NAME" -o "$TMP/$NAME"
  [[ "$(shasum -a 256 "$TMP/$NAME" | cut -d' ' -f1)" == "$DIGEST" ]] || { echo "Sparkle download checksum mismatch" >&2; exit 1; }
  mv "$TMP/$NAME" "$ARCHIVE"
fi
[[ "$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)" == "$DIGEST" ]] || { echo "Sparkle archive checksum mismatch: $ARCHIVE" >&2; exit 1; }
if [[ ! -d "$BIN" ]]; then
  STAGE="$(mktemp -d "$CACHE/.unpack.XXXXXX")"
  tar -xf "$ARCHIVE" -C "$STAGE" ./bin ./Sparkle.framework ./LICENSE
  mv "$STAGE" "$BIN"
fi
# Never run a modified tool from an existing extraction. These hashes belong
# to the executables in the pinned, universal release archive above.
(cd "$BIN" && shasum -a 256 -c - >/dev/null <<'HASHES'
c37679f98d9121981cf7b2d18592fdc8b44931bffa604acf10c9e11791b6222e  bin/generate_keys
43c249771bafc3aa581228abae00731a012d324691b8292860896635050be76b  bin/sign_update
cdc53c1da293c5f89648929678df2072f72a9f18d91744a06fcb8cc0e12a3219  bin/generate_appcast
9c78b2046e7637efeb8ca505d63170bc1557651925dbbfd45ac236845732b05a  Sparkle.framework/Sparkle
HASHES
)
case "$#" in
  0) ;;
  2)
    [[ "$1" == --extract-framework-to ]] || { echo "Unknown option $1" >&2; exit 2; }
    # Require a fresh directory so no stale helpers or files can be shipped.
    mkdir "$2"
    tar -xf "$ARCHIVE" -C "$2" ./Sparkle.framework ./LICENSE
    ;;
  *) echo "usage: $0 [--extract-framework-to NEW_DIRECTORY]" >&2; exit 2 ;;
esac
echo "$BIN"
