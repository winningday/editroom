#!/bin/zsh
# Builds a signed, notarized Editroom DMG that opens without warnings on any Mac: dist/Editroom-<version>.dmg.
# This fork has no update feed: copy the DMG to the Mac by hand. Nothing updates itself.
#
# Needs, all kept out of this repository:
#   - a "Developer ID Application" certificate in the login keychain
#   - notarization credentials saved once with:
#       xcrun notarytool store-credentials "editroom-notary" --apple-id "…" --team-id "$EDITROOM_TEAM"
#   - create-dmg (brew install create-dmg)
# Raise MARKETING_VERSION and CURRENT_PROJECT_VERSION in the project before each release.
# Set EDITROOM_TEAM to your own Apple Developer Team ID first.
# The DMG window background is scripts/dmg/background.png (600 × 380) and background@2x.png (1200 × 760).
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP=Editroom
TEAM="${EDITROOM_TEAM:?Set EDITROOM_TEAM to your Apple Developer Team ID}"
IDENTITY="Developer ID Application"
NOTARY_PROFILE=editroom-notary
# Built outside Dropbox: the extended attributes it adds to files make code signing fail.
WORK="$HOME/Library/Caches/EditroomRelease"
DIST="$PROJECT_DIR/dist"

command -v create-dmg >/dev/null || { echo "create-dmg is missing: brew install create-dmg"; exit 1 }

settings=$(xcodebuild -project "$PROJECT_DIR/$APP.xcodeproj" -scheme "$APP" -configuration Release -showBuildSettings 2>/dev/null)
VERSION=$(print -r -- "$settings" | awk -F' = ' '/ MARKETING_VERSION = /{print $2; exit}')
BUILD=$(print -r -- "$settings" | awk -F' = ' '/ CURRENT_PROJECT_VERSION = /{print $2; exit}')
echo "==> $APP $VERSION ($BUILD)"

rm -rf "$WORK"
mkdir -p "$WORK" "$DIST"

echo "==> Archiving a Release build"
xcodebuild archive -quiet \
  -project "$PROJECT_DIR/$APP.xcodeproj" -scheme "$APP" -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$WORK/$APP.xcarchive" -derivedDataPath "$WORK/DerivedData" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM"

echo "==> Exporting, signed with Developer ID"
xcodebuild -exportArchive -quiet \
  -archivePath "$WORK/$APP.xcarchive" \
  -exportOptionsPlist "$PROJECT_DIR/scripts/ExportOptions.plist" \
  -exportPath "$WORK/export"
APP_PATH="$WORK/export/$APP.app"
# The bundled ffmpeg is signed on copy without a secure timestamp, which notarization refuses. Signed again with one,
# then the app around it, so the app's seal covers the new signature.
codesign --force --sign "$IDENTITY" --timestamp --options runtime "$APP_PATH/Contents/MacOS/ffmpeg"
codesign --force --sign "$IDENTITY" --timestamp --options runtime --preserve-metadata=entitlements,requirements,flags "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Notarizing the app"
ditto -c -k --keepParent "$APP_PATH" "$WORK/$APP.zip"
xcrun notarytool submit "$WORK/$APP.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"

echo "==> Building the DMG window"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/"
DMG="$DIST/$APP-$VERSION.dmg"
rm -f "$DMG"
# Finder takes one background file; a TIFF holding both sizes stays sharp on Retina displays.
sips -s dpiWidth 72 -s dpiHeight 72 "$PROJECT_DIR/scripts/dmg/background.png" --out "$WORK/background.png" >/dev/null
sips -s dpiWidth 144 -s dpiHeight 144 "$PROJECT_DIR/scripts/dmg/background@2x.png" --out "$WORK/background@2x.png" >/dev/null
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" >/dev/null
# The window is 600 × 412 points: the 380-point background plus the 32-point title bar. 148-point icons sit
# side by side, 160 and 440 across (even about the 300-point middle), 180 down.
create-dmg \
  --volname "$APP" \
  --background "$WORK/background.tiff" \
  --window-pos 200 120 --window-size 600 412 \
  --icon-size 148 --text-size 13 \
  --icon "$APP.app" 160 180 --hide-extension "$APP.app" \
  --app-drop-link 440 180 \
  --no-internet-enable \
  "$DMG" "$STAGE"

echo "==> Signing and notarizing the DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> What Gatekeeper will say on another Mac"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
spctl --assess --type execute --verbose=2 "$APP_PATH"
echo "==> Done: $DMG"
