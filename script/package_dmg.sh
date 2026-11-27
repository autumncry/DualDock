#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
python3 "$ROOT_DIR/script/check_installation_guidance.py"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")"
APP_PATH="$("$ROOT_DIR/script/package_app.sh" release "$@")"
ARCH="$(lipo -archs "$APP_PATH/Contents/MacOS/DualDock3")"
case "$ARCH" in
  arm64|x86_64) ARCH_SUFFIX="$ARCH" ;;
  *) echo "Unexpected release architecture: $ARCH" >&2; exit 1 ;;
esac
ASSET_NAME="DualDock-$VERSION-$ARCH_SUFFIX.dmg"
STAGING_DIR="$(mktemp -d "$DIST_DIR/.dualdock-dmg.XXXXXX")"
MOUNT_POINT="$STAGING_DIR/mount"
DMG_MOUNTED=0
cleanup() {
  if [ "$DMG_MOUNTED" = 1 ]; then
    if ! hdiutil detach "$MOUNT_POINT" >&2; then
      echo "Could not unmount $MOUNT_POINT; keeping temporary files for cleanup." >&2
      return
    fi
  fi
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT
mkdir -p "$STAGING_DIR/volume"
ditto "$APP_PATH" "$STAGING_DIR/volume/DualDock 3.app"
ln -s /Applications "$STAGING_DIR/volume/Applications"
cp "$ROOT_DIR/docs/first-launch.html" "$STAGING_DIR/volume/首次安装 - First Launch.html"
cp "$ROOT_DIR/docs/installation.txt" "$STAGING_DIR/volume/安装说明.txt"
cp "$ROOT_DIR/LICENSE" "$STAGING_DIR/volume/LICENSE.txt"
codesign --verify --strict "$STAGING_DIR/volume/DualDock 3.app" >&2
hdiutil create -volname "DualDock 3" -srcfolder "$STAGING_DIR/volume" \
  -fs HFS+ -format UDZO "$STAGING_DIR/$ASSET_NAME" >&2
hdiutil verify "$STAGING_DIR/$ASSET_NAME" >&2
mkdir -p "$MOUNT_POINT"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$STAGING_DIR/$ASSET_NAME" >&2
DMG_MOUNTED=1
python3 "$ROOT_DIR/script/check_installation_guidance.py" --volume "$MOUNT_POINT"
hdiutil detach "$MOUNT_POINT" >&2
DMG_MOUNTED=0
mv "$STAGING_DIR/$ASSET_NAME" "$DIST_DIR/$ASSET_NAME"
(
  cd "$DIST_DIR"
  shasum -a 256 "$ASSET_NAME" > "$ASSET_NAME.sha256"
  shasum -a 256 -c "$ASSET_NAME.sha256" >&2
)
echo "$DIST_DIR/$ASSET_NAME"
