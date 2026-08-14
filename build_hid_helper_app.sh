#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
APP_DIR="${RC001_HID_HELPER_OUTPUT:-$PROJECT_DIR/dist/RC001-Viber HID Helper.app}"
CONTENTS_DIR="$APP_DIR/Contents"
if [[ -n "${RC001_CODE_SIGN_IDENTITY:-}" ]]; then
  CODE_SIGN_IDENTITY="$RC001_CODE_SIGN_IDENTITY"
else
  CODE_SIGN_IDENTITY=$(
    /usr/bin/security find-identity -v -p codesigning \
      | /usr/bin/awk '/"Developer ID Application:/ && !found { print $2; found = 1 }'
  )
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
fi

cd "$PROJECT_DIR"
"$PROJECT_DIR/generate_app_icon.sh"
swift build -c release --product rc001-hid-helper
BIN_DIR="$(swift build -c release --show-bin-path)"

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BIN_DIR/rc001-hid-helper" "$CONTENTS_DIR/MacOS/rc001-hid-helper"
cp "$PROJECT_DIR/Resources/RC001HIDHelper-Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/RC001-Viber.icns" "$CONTENTS_DIR/Resources/RC001-Viber.icns"
CODE_SIGN_OPTIONS=(--force --deep)
if [[ "$CODE_SIGN_IDENTITY" != '-' ]]; then
  CODE_SIGN_OPTIONS+=(--timestamp --options runtime)
fi
codesign "${CODE_SIGN_OPTIONS[@]}" --sign "$CODE_SIGN_IDENTITY" "$APP_DIR"

print "$APP_DIR"
