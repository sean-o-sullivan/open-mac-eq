#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PROJECT="$ROOT/AirPodsEQSpike.xcodeproj"
DERIVED="$ROOT/.build-package"
DIST="$ROOT/dist"
STAGE="$ROOT/.package-stage"
APP_SOURCE="$DERIVED/Build/Products/Release/openEq.app"
APP_DESTINATION="$DIST/openEq.app"
DMG="$DIST/openEq-1.0.dmg"
ZIP="$DIST/openEq-1.0.zip"
LICENSE_SOURCE="$ROOT/LICENSE"
SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:--}"

[[ -f "$LICENSE_SOURCE" ]] || { print -u2 "Missing LICENSE"; exit 1; }

/bin/rm -rf "$DERIVED" "$STAGE" "$APP_DESTINATION" "$DMG" "$ZIP"
/bin/mkdir -p "$DIST" "$STAGE"

/usr/bin/xcodebuild \
  -quiet \
  -project "$PROJECT" \
  -scheme AirPodsEQSpike \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  build

/bin/cp "$LICENSE_SOURCE" "$APP_SOURCE/Contents/Resources/LICENSE"

/usr/bin/codesign \
  --force \
  --deep \
  --sign "$SIGN_IDENTITY" \
  --options runtime \
  --identifier app.openmaceq.openEq \
  "$APP_SOURCE"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_SOURCE"
/usr/bin/ditto "$APP_SOURCE" "$APP_DESTINATION"
/usr/bin/ditto "$APP_SOURCE" "$STAGE/openEq.app"
/bin/cp "$LICENSE_SOURCE" "$STAGE/LICENSE"
/bin/ln -s /Applications "$STAGE/Applications"

/usr/bin/hdiutil create \
  -volname "openEq" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG"

COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --keepParent --norsrc --noextattr "$APP_SOURCE" "$ZIP"
/bin/rm -rf "$STAGE"

print "App: $APP_DESTINATION"
print "DMG: $DMG"
print "ZIP: $ZIP"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  print "Signing: local ad-hoc. Developer ID notarization still required for public distribution."
else
  print "Signing: $SIGN_IDENTITY"
fi
