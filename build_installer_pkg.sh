#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
PACKAGE_PATH="$PROJECT_DIR/dist/RC001-Viber-0.1.10.pkg"
STAGING_DIR="$(mktemp -d '/tmp/rc001-mac-bridge-package.XXXXXX')"
PAYLOAD_DIR="$STAGING_DIR/payload"
SCRIPTS_DIR="$STAGING_DIR/scripts"
COMPONENT_PLIST="$STAGING_DIR/components.plist"
BUILD_APP_DIR="$STAGING_DIR/build/RC001-Viber.app"
BUILD_HELPER_DIR="$STAGING_DIR/build/RC001-Viber HID Helper.app"
export COPYFILE_DISABLE=1

RC001_APP_OUTPUT="$BUILD_APP_DIR" "$PROJECT_DIR/build_probe_app.sh"
RC001_HID_HELPER_OUTPUT="$BUILD_HELPER_DIR" "$PROJECT_DIR/build_hid_helper_app.sh"
"$PROJECT_DIR/build_audio_driver.sh"

mkdir -p \
  "$PAYLOAD_DIR/Applications" \
  "$PAYLOAD_DIR/Library/Audio/Plug-Ins/HAL" \
  "$PAYLOAD_DIR/Library/LaunchDaemons" \
  "$SCRIPTS_DIR"

ditto --norsrc --noextattr \
  "$BUILD_APP_DIR" \
  "$PAYLOAD_DIR/Applications/RC001-Viber.app"
ditto --norsrc --noextattr \
  "$BUILD_HELPER_DIR" \
  "$PAYLOAD_DIR/Applications/RC001-Viber HID Helper.app"
ditto --norsrc --noextattr \
  "$PROJECT_DIR/dist/RC001 Remote Microphone.driver" \
  "$PAYLOAD_DIR/Library/Audio/Plug-Ins/HAL/RC001 Remote Microphone.driver"
cp \
  "$PROJECT_DIR/Resources/com.wangxi.RC001Viber.HIDHelper.plist" \
  "$PAYLOAD_DIR/Library/LaunchDaemons/com.wangxi.RC001Viber.HIDHelper.plist"
cp "$PROJECT_DIR/Driver/Scripts/postinstall" "$SCRIPTS_DIR/postinstall"
chmod +x "$SCRIPTS_DIR/postinstall"
xattr -cr "$PAYLOAD_DIR" "$SCRIPTS_DIR"

# Keep the app at /Applications even when a development copy exists elsewhere.
# Without this flag, Installer's bundle relocation can silently target dist/.
pkgbuild --analyze --root "$PAYLOAD_DIR" "$COMPONENT_PLIST"
component_count=$(/usr/libexec/PlistBuddy -c 'Print' "$COMPONENT_PLIST" | /usr/bin/grep -c 'Dict {')
for (( component_index = 0; component_index < component_count; component_index++ )); do
  if ! /usr/libexec/PlistBuddy \
    -c "Set :${component_index}:BundleIsRelocatable false" \
    "$COMPONENT_PLIST" 2>/dev/null; then
    /usr/libexec/PlistBuddy \
      -c "Add :${component_index}:BundleIsRelocatable bool false" \
      "$COMPONENT_PLIST"
  fi
done

pkgbuild \
  --root "$PAYLOAD_DIR" \
  --scripts "$SCRIPTS_DIR" \
  --component-plist "$COMPONENT_PLIST" \
  --identifier 'com.wangxi.RC001MacBridge' \
  --version '0.1.10' \
  --install-location '/' \
  "$PACKAGE_PATH"

print "$PACKAGE_PATH"
