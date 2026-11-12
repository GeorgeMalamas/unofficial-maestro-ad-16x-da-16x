#!/bin/bash
# build-sip-off-pkg.sh — Build an installable .pkg for SIP-disabled Macs (ad-hoc signed, no Developer ID required)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
PAYLOAD_DIR="$BUILD_DIR/payload"
OUTPUT_DIR="$BUILD_DIR/output"

VERSION=$(grep -o '"[0-9]*\.[0-9]*\.[0-9]*"' "$REPO_ROOT/Apps/Maestro/MaestroCore/MaestroCore.swift" | tr -d '"' || echo "0.8.34")
BUILD_NUM="1031"
SIGN_ID="${SIGNING_IDENTITY:--}"

rm -rf "$BUILD_DIR"
mkdir -p "$PAYLOAD_DIR" "$OUTPUT_DIR"

echo "=== [1/4] Building 64-Channel ThunderBridge DriverKit Extension (.dext) ==="
bash "$REPO_ROOT/Drivers/Thunderbolt/Scripts/build.sh" --clean --production

echo "=== [2/4] Building Maestro.app (Release) ==="
swift build --package-path "$REPO_ROOT/Apps/Maestro" -c release --jobs "${MAESTRO_BUILD_JOBS:-4}"

echo "=== [3/4] Building AudioServerPlugin & VolumeProxy ==="
bash "$REPO_ROOT/Drivers/AudioServerPlugin/Scripts/build.sh"
clang -o "$BUILD_DIR/MaestroVolumeProxy" "$REPO_ROOT/Drivers/VolumeProxy/MaestroVolumeProxy.c" \
    -I "$REPO_ROOT/Drivers/Shared" \
    -arch arm64 \
    -mmacosx-version-min=15.0 \
    -framework Foundation \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework IOKit \
    -Wall -Wextra -O2

echo "=== [4/4] Assembling, Ad-Hoc Signing & Packaging .pkg ==="
APP_BINARY="$REPO_ROOT/Apps/Maestro/.build/release/MaestroApp"
APP_RESOURCES="$REPO_ROOT/Apps/Maestro/MaestroApp/Resources"
APP_BUNDLE="$PAYLOAD_DIR/Applications/Maestro.app"

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"
cp "$APP_BINARY" "$APP_BUNDLE/Contents/MacOS/MaestroApp"

if otool -l "$APP_BUNDLE/Contents/MacOS/MaestroApp" | awk '$1 == "path" && $2 == "@loader_path" { found = 1 } END { exit found ? 0 : 1 }'; then
    install_name_tool -delete_rpath "@loader_path" "$APP_BUNDLE/Contents/MacOS/MaestroApp"
fi
install_name_tool -add_rpath "@loader_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/MaestroApp"

cp "$APP_RESOURCES/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_BUNDLE/Contents/Info.plist"

for RES in AppIcon.icns AppIconRounded.icns Acknowledgements.html Privacy.html Terms.html; do
    [ -f "$APP_RESOURCES/$RES" ] && cp "$APP_RESOURCES/$RES" "$APP_BUNDLE/Contents/Resources/$RES"
done

SPARKLE_SRC="$REPO_ROOT/Apps/Maestro/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$SPARKLE_SRC" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

[ -f "$REPO_ROOT/docs/UserManual.md" ] && cp "$REPO_ROOT/docs/UserManual.md" "$APP_BUNDLE/Contents/Resources/UserManual.md"
cp "$SCRIPT_DIR/uninstall.sh" "$APP_BUNDLE/Contents/Resources/uninstall.sh"
chmod 755 "$APP_BUNDLE/Contents/Resources/uninstall.sh"

DEXT_BUNDLE="com.danielraffel.maestro.thunderbridge.dext"
DEXT_SRC="$REPO_ROOT/Drivers/Thunderbolt/build/$DEXT_BUNDLE"
rm -f "$DEXT_SRC/embedded.provisionprofile"

codesign --sign "$SIGN_ID" --force --options runtime \
    --entitlements "$REPO_ROOT/Drivers/Thunderbolt/Entitlements/SymphonyThunderbridge.entitlements" \
    --generate-entitlement-der \
    "$DEXT_SRC"

mkdir -p "$APP_BUNDLE/Contents/Library/SystemExtensions"
ditto "$DEXT_SRC" "$APP_BUNDLE/Contents/Library/SystemExtensions/$DEXT_BUNDLE"

mkdir -p "$PAYLOAD_DIR/Library/Audio/Plug-Ins/HAL"
cp -R "$REPO_ROOT/Drivers/AudioServerPlugin/build/ApogeeSymIO.driver" "$PAYLOAD_DIR/Library/Audio/Plug-Ins/HAL/ApogeeSymIO.driver"

mkdir -p "$PAYLOAD_DIR/usr/local/bin"
cp "$BUILD_DIR/MaestroVolumeProxy" "$PAYLOAD_DIR/usr/local/bin/MaestroVolumeProxy"

mkdir -p "$PAYLOAD_DIR/Library/LaunchDaemons"
cp "$REPO_ROOT/Drivers/VolumeProxy/com.danielraffel.Maestro.volumeproxy.plist" "$PAYLOAD_DIR/Library/LaunchDaemons/com.danielraffel.Maestro.volumeproxy.plist"

find "$PAYLOAD_DIR" -name '._*' -delete 2>/dev/null || true

codesign --sign "$SIGN_ID" --force --deep --options runtime "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
codesign --sign "$SIGN_ID" --force --options runtime \
    --entitlements "$REPO_ROOT/Apps/Maestro/Maestro.entitlements" \
    --generate-entitlement-der \
    "$APP_BUNDLE"
codesign --sign "$SIGN_ID" --force --deep --options runtime "$PAYLOAD_DIR/Library/Audio/Plug-Ins/HAL/ApogeeSymIO.driver"
codesign --sign "$SIGN_ID" --force --options runtime "$PAYLOAD_DIR/usr/local/bin/MaestroVolumeProxy"

chmod +x "$SCRIPT_DIR/scripts-core/preinstall" "$SCRIPT_DIR/scripts-core/postinstall" "$SCRIPT_DIR/scripts-usb/postinstall"

CORE_ROOT="$BUILD_DIR/payload-core"
USB_ROOT="$BUILD_DIR/payload-usb"
mkdir -p "$CORE_ROOT/Applications" "$USB_ROOT"
ditto "$PAYLOAD_DIR/Applications/Maestro.app" "$CORE_ROOT/Applications/Maestro.app"
for p in Library/Audio/Plug-Ins/HAL/ApogeeSymIO.driver usr/local/bin/MaestroVolumeProxy \
         Library/LaunchDaemons/com.danielraffel.Maestro.volumeproxy.plist; do
    mkdir -p "$USB_ROOT/$(dirname "$p")"
    ditto "$PAYLOAD_DIR/$p" "$USB_ROOT/$p"
done

make_component_plist() {
    pkgbuild --analyze --root "$1" "$2" >/dev/null
    python3 - "$2" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    comps = plistlib.load(f)
for c in comps:
    c['BundleIsRelocatable'] = False
with open(path, 'wb') as f:
    plistlib.dump(comps, f)
PY
}

CORE_PKG="$BUILD_DIR/SymphonyMaestroCore.pkg"
USB_PKG="$BUILD_DIR/SymphonyMaestroUSB.pkg"

make_component_plist "$CORE_ROOT" "$BUILD_DIR/component-core.plist"
pkgbuild --root "$CORE_ROOT" --component-plist "$BUILD_DIR/component-core.plist" \
    --scripts "$SCRIPT_DIR/scripts-core" --identifier "com.generouscorp.maestro.core" \
    --version "$VERSION" --ownership recommended "$CORE_PKG" >/dev/null

make_component_plist "$USB_ROOT" "$BUILD_DIR/component-usb.plist"
pkgbuild --root "$USB_ROOT" --component-plist "$BUILD_DIR/component-usb.plist" \
    --scripts "$SCRIPT_DIR/scripts-usb" --identifier "com.generouscorp.maestro.usb" \
    --version "$VERSION" --ownership recommended "$USB_PKG" >/dev/null

DIST_XML="$BUILD_DIR/distribution.xml"
sed "s/version=\"[0-9]*\.[0-9]*\.[0-9]*\"/version=\"$VERSION\"/g" "$SCRIPT_DIR/distribution.xml" > "$DIST_XML"

DIST_PKG="$OUTPUT_DIR/UnofficialSymphonyMaestro-${VERSION}-64ch-SIP-Off.pkg"
productbuild --distribution "$DIST_XML" --resources "$SCRIPT_DIR/resources" \
    --package-path "$BUILD_DIR" --version "$VERSION" "$DIST_PKG"

echo ""
echo "============================================================"
echo "  SIP-Off Installer ready: $DIST_PKG"
echo "============================================================"
