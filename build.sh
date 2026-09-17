#!/bin/bash
# Builds <APP_NAME>.app and a distributable .dmg.
# Rename the app by changing APP_NAME here and in Sources/AppInfo.swift.
set -euo pipefail

APP_NAME="Nyquist"
BUNDLE_ID="com.gregoregan.nyquist"
VERSION="1.0"
MIN_MACOS="12.0"

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
DMG="$BUILD/$APP_NAME-$VERSION.dmg"

echo "==> Cleaning"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling (arm64, macOS $MIN_MACOS+)"
swiftc -O -whole-module-optimization \
    -target "arm64-apple-macosx$MIN_MACOS" \
    -framework AppKit -framework AVFoundation -framework Accelerate \
    -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers \
    "$ROOT"/Sources/*.swift \
    -o "$APP/Contents/MacOS/$APP_NAME"

echo "==> Building icon"
ICONSET="$BUILD/$APP_NAME.iconset"
mkdir -p "$ICONSET" "$BUILD/icons"
swiftc -O "$ROOT/Tools/makeicon.swift" -o "$BUILD/makeicon"
"$BUILD/makeicon" "$BUILD/icons" >/dev/null
cp "$BUILD/icons/icon_16.png"   "$ICONSET/icon_16x16.png"
cp "$BUILD/icons/icon_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$BUILD/icons/icon_32.png"   "$ICONSET/icon_32x32.png"
cp "$BUILD/icons/icon_64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$BUILD/icons/icon_128.png"  "$ICONSET/icon_128x128.png"
cp "$BUILD/icons/icon_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$BUILD/icons/icon_256.png"  "$ICONSET/icon_256x256.png"
cp "$BUILD/icons/icon_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$BUILD/icons/icon_512.png"  "$ICONSET/icon_512x512.png"
cp "$BUILD/icons/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/$APP_NAME.icns"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Gregor Egan</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Audio File</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.audio</string>
                <string>public.mp3</string>
                <string>public.aiff-audio</string>
                <string>com.microsoft.waveform-audio</string>
                <string>org.xiph.flac</string>
                <string>com.apple.m4a-audio</string>
                <string>public.mpeg-4-audio</string>
                <string>com.apple.coreaudio-format</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - --options runtime "$APP" 2>/dev/null \
  || codesign --force --deep --sign - "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Building disk image"
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me first.txt" <<TXT
$APP_NAME $VERSION

1. Drag $APP_NAME to the Applications folder.
2. Eject this disk image.
3. Open Terminal and run this once:

       xattr -dr com.apple.quarantine /Applications/$APP_NAME.app

4. Launch $APP_NAME normally from then on.

Step 3 is not optional. $APP_NAME is signed but not notarized by Apple, and
macOS quarantines anything downloaded from the internet. Without that command
macOS will refuse to open it, usually claiming the app is "damaged" — it is not,
that is just what Gatekeeper says about un-notarized apps.

The old trick of control-clicking and choosing Open no longer works: Apple
removed that bypass in macOS 15. On macOS 15 and later you can alternatively try
to open the app, then go to System Settings > Privacy & Security and click
"Open Anyway" near the bottom. The Terminal command above is more reliable.

Requires an Apple Silicon Mac running macOS $MIN_MACOS or later.
TXT

hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO -quiet "$DMG"

rm -rf "$STAGE" "$ICONSET" "$BUILD/icons" "$BUILD/makeicon"

echo ""
echo "    App:  $APP"
echo "    DMG:  $DMG  ($(du -h "$DMG" | cut -f1))"
echo "==> Done"
