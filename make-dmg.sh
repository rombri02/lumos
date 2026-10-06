#!/bin/sh
# Builds Lumos and packs it in build/Lumos-<version>.dmg with a styled install window:
# themed background (dmg/background.swift), big icons, drag-to-Applications arrow.
# Release: SIGN_ID="Developer ID Application: ..." NOTARY_PROFILE=notary ./make-dmg.sh
set -e
cd "$(dirname "$0")"
export VERSION=${VERSION:-1.0.1}
./build.sh

VOL="Lumos"
DMG="build/Lumos-$VERSION.dmg"
TMP=$(mktemp -d)
RW="$TMP/rw.dmg"

# Background: 1x + 2x merged in one HiDPI TIFF so it's sharp on Retina.
swiftc dmg/background.swift -o "$TMP/mkbg"
"$TMP/mkbg" "$TMP/bg.png" "$TMP/bg@2x.png"
tiffutil -cathidpicheck "$TMP/bg.png" "$TMP/bg@2x.png" -out "$TMP/background.tiff" >/dev/null

# A stale mount with the same name would make Finder style the wrong window.
[ -d "/Volumes/$VOL" ] && hdiutil detach "/Volumes/$VOL" -force >/dev/null

hdiutil create -volname "$VOL" -fs HFS+ -size 40m -type UDIF -layout NONE -ov "$RW" >/dev/null 2>&1
MNT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')

cp -R build/Lumos.app "$MNT/"
ln -s /Applications "$MNT/Applications"
mkdir "$MNT/.background"
cp "$TMP/background.tiff" "$MNT/.background/background.tiff"
cp build/Lumos.app/Contents/Resources/AppIcon.icns "$MNT/.VolumeIcon.icns"
SetFile -a C "$MNT"               # use .VolumeIcon.icns as the disk icon
SetFile -a E "$MNT/Lumos.app"     # show "Lumos", not "Lumos.app"

# Window layout (positions must match dmg/background.swift). Saved into the DMG's .DS_Store.
osascript <<EOF
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        set bounds of container window to {200, 120, 840, 568}
        set opts to icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "Lumos.app" of container window to {160, 200}
        set position of item "Applications" of container window to {480, 200}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

chmod -Rf go-w "$MNT" || true
sync
hdiutil detach "$MNT" >/dev/null
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -rf "$TMP"

# NOTARY_PROFILE = name saved with `xcrun notarytool store-credentials`.
if [ -n "$NOTARY_PROFILE" ]; then
    codesign -s "$SIGN_ID" --timestamp "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi
echo "Created $DMG"
