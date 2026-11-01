#!/bin/sh
# Packs build/Dandelion.app into Dandelion.dmg: open it, drag Dandelion onto Applications.
# Run ./build.sh first.
set -e
cd "$(dirname "$0")"

APP="build/Dandelion.app"
DMG="build/Dandelion.dmg"
[ -d "$APP" ] || { echo "No $APP yet. Run ./build.sh first."; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Dandelion" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --force --sign - "$DMG"

echo "Made $DMG ($(du -h "$DMG" | cut -f1))"
