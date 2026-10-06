#!/bin/sh
# Builds build/Lumos.app.  ./build.sh --install  also installs it in /Applications.
# Needs Xcode 26+ (actool compiles the Icon Composer icon).
set -e
cd "$(dirname "$0")"
VERSION=${VERSION:-1.0.2}
BUNDLE_ID=io.github.rombri02.lumos
APP=build/Lumos.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Liquid Glass UI needs macOS 26; every Mac with an XDR/HDR panel is Apple Silicon.
swiftc -O -target arm64-apple-macos26.0 main.swift UI.swift -o "$APP/Contents/MacOS/Lumos"

# App icon: AppIcon.icon (Icon Composer format, needed on macOS 26+ to avoid the grey
# "icon jail") = icon.json fill (yellow gradient) + glyph rendered by icon.swift.
TMP=$(mktemp -d)
cp -R AppIcon.icon "$TMP/"
mkdir -p "$TMP/AppIcon.icon/Assets"
swiftc icon.swift -o "$TMP/mkicon"
"$TMP/mkicon" "$TMP/AppIcon.icon/Assets/wand.png"
xcrun actool "$TMP/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon --output-partial-info-plist "$TMP/partial.plist" >/dev/null
rm -rf "$TMP"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Lumos</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Lumos</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
# SIGN_ID unset = ad-hoc (local builds). Release: SIGN_ID="Developer ID Application: ..."
# Hardened runtime + timestamp are required for notarization.
if [ -n "$SIGN_ID" ]; then
    codesign -s "$SIGN_ID" --force --options runtime --timestamp "$APP"
else
    codesign -s - --force "$APP"
fi
echo "Built $APP ($VERSION)"

if [ "$1" = "--install" ]; then
    # Move (not copy) so Spotlight / the Apps drawer don't list two Lumos.
    pkill -x Lumos || true
    rm -rf /Applications/Lumos.app
    mv "$APP" /Applications/
    echo "Installed /Applications/Lumos.app"
fi
