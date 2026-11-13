#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
CORE_ROOT="$BUILD_DIR/payload-core"
OUTPUT_DIR="$BUILD_DIR/output"

VERSION="99.8.34"
SIGN_ID="-"

rm -rf "$BUILD_DIR"
mkdir -p "$CORE_ROOT/Applications" "$OUTPUT_DIR"

DK_VER=$(xcrun --sdk driverkit --show-sdk-version)
echo "Detected DriverKit SDK version: $DK_VER"

sed -i '' "s/driverkit25\.2/driverkit${DK_VER}/g" "$REPO_ROOT/Drivers/Thunderbolt/Scripts/build.sh"
sed -i '' "s/--deployment-target 25\.2/--deployment-target ${DK_VER}/g" "$REPO_ROOT/Drivers/Thunderbolt/Scripts/build.sh"

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 122" "$REPO_ROOT/Drivers/Thunderbolt/Info.plist"
/usr/libexec/PlistBuddy -c "Set :DTPlatformVersion $DK_VER" "$REPO_ROOT/Drivers/Thunderbolt/Info.plist"
/usr/libexec/PlistBuddy -c "Set :OSMinimumDriverKitVersion $DK_VER" "$REPO_ROOT/Drivers/Thunderbolt/Info.plist"

echo "=== [1/3] Building 64-Channel ThunderBridge DriverKit Extension (.dext) ==="
bash "$REPO_ROOT/Drivers/Thunderbolt/Scripts/build.sh" --clean

echo "=== [2/3] Compiling MaestroApp (arm64) via swiftc ==="
SWIFTC=$(xcrun --sdk macosx -f swiftc)
SDK=$(xcrun --sdk macosx --show-sdk-path)
BUILD_TMP="$BUILD_DIR/swift-objs"
mkdir -p "$BUILD_TMP"

"$SWIFTC" -O -whole-module-optimization -suppress-warnings \
    -sdk "$SDK" -target arm64-apple-macosx15.0 \
    -parse-as-library -emit-library -static -emit-module \
    -module-name MaestroCore \
    -emit-module-path "$BUILD_TMP/MaestroCore.swiftmodule" \
    -o "$BUILD_TMP/libMaestroCore.a" \
    "$REPO_ROOT"/Apps/Maestro/MaestroCore/*.swift

"$SWIFTC" -O -whole-module-optimization -suppress-warnings \
    -sdk "$SDK" -target arm64-apple-macosx15.0 \
    -I "$BUILD_TMP" \
    -parse-as-library -emit-library -static -emit-module \
    -module-name MaestroDevice \
    -emit-module-path "$BUILD_TMP/MaestroDevice.swiftmodule" \
    -o "$BUILD_TMP/libMaestroDevice.a" \
    "$REPO_ROOT"/Apps/Maestro/MaestroDevice/*.swift

"$SWIFTC" -O -whole-module-optimization -suppress-warnings \
    -sdk "$SDK" -target arm64-apple-macosx15.0 \
    -I "$BUILD_TMP" \
    -parse-as-library \
    -module-name MaestroApp \
    "$REPO_ROOT"/Apps/Maestro/MaestroApp/*.swift \
    "$BUILD_TMP/libMaestroDevice.a" \
    "$BUILD_TMP/libMaestroCore.a" \
    -framework SwiftUI -framework AppKit -framework Combine \
    -framework ApplicationServices -framework CoreAudio -framework CoreGraphics \
    -framework IOKit -framework IOUSBHost -framework SystemExtensions \
    -framework Accelerate -framework UniformTypeIdentifiers \
    -o "$BUILD_TMP/MaestroApp"

echo "=== [3/3] Assembling, Ad-Hoc Signing & Packaging .pkg ==="
APP_RESOURCES="$REPO_ROOT/Apps/Maestro/MaestroApp/Resources"
APP_BUNDLE="$CORE_ROOT/Applications/Maestro.app"

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" \
         "$APP_BUNDLE/Contents/Library/SystemExtensions"
cp "$BUILD_TMP/MaestroApp" "$APP_BUNDLE/Contents/MacOS/MaestroApp"
cp "$APP_RESOURCES/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_BUNDLE/Contents/Info.plist"

for RES in AppIcon.icns AppIconRounded.icns Acknowledgements.html Privacy.html Terms.html; do
    [ -f "$APP_RESOURCES/$RES" ] && cp "$APP_RESOURCES/$RES" "$APP_BUNDLE/Contents/Resources/$RES"
done

[ -f "$REPO_ROOT/docs/UserManual.md" ] && cp "$REPO_ROOT/docs/UserManual.md" "$APP_BUNDLE/Contents/Resources/UserManual.md"
cp "$SCRIPT_DIR/uninstall.sh" "$APP_BUNDLE/Contents/Resources/uninstall.sh"
chmod 755 "$APP_BUNDLE/Contents/Resources/uninstall.sh"

DEXT_BUNDLE="com.danielraffel.maestro.thunderbridge.dext"
DEXT_SRC="$REPO_ROOT/Drivers/Thunderbolt/build/$DEXT_BUNDLE"
rm -f "$DEXT_SRC/embedded.provisionprofile"

codesign --sign "$SIGN_ID" --force --options runtime \
    --entitlements "$REPO_ROOT/Drivers/Thunderbolt/Entitlements/SymphonyThunderbridge.entitlements" \
    --generate-entitlement-der "$DEXT_SRC"
ditto "$DEXT_SRC" "$APP_BUNDLE/Contents/Library/SystemExtensions/$DEXT_BUNDLE"

find "$CORE_ROOT" -name '._*' -delete 2>/dev/null || true

codesign --sign "$SIGN_ID" --force --options runtime \
    --entitlements "$REPO_ROOT/Apps/Maestro/Maestro.entitlements" \
    --generate-entitlement-der "$APP_BUNDLE"

chmod +x "$SCRIPT_DIR/scripts-core/preinstall" "$SCRIPT_DIR/scripts-core/postinstall"
pkgbuild --analyze --root "$CORE_ROOT" "$BUILD_DIR/component-core.plist" >/dev/null
python3 - "$BUILD_DIR/component-core.plist" << 'PY'
import plistlib, sys
p = sys.argv[1]
with open(p, "rb") as f:
    c = plistlib.load(f)
for x in c:
    x["BundleIsRelocatable"] = False
with open(p, "wb") as f:
    plistlib.dump(c, f)
PY

DIST_PKG="$OUTPUT_DIR/UnofficialSymphonyMaestro-64ch-SIP-Off.pkg"
pkgbuild --root "$CORE_ROOT" --component-plist "$BUILD_DIR/component-core.plist" \
    --scripts "$SCRIPT_DIR/scripts-core" --identifier "com.generouscorp.maestro.core" \
    --version "$VERSION" --ownership recommended "$DIST_PKG"

echo "SIP-Off Installer ready: $DIST_PKG"
