#!/bin/sh
# Builds Lumos and packs it in build/Lumos-<version>.dmg (drag-to-Applications layout).
set -e
cd "$(dirname "$0")"
export VERSION=${VERSION:-1.0.0}
./build.sh

STAGE=$(mktemp -d)
cp -R build/Lumos.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="build/Lumos-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Lumos" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Created $DMG"
