#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
APP_DIR="${RC001_APP_OUTPUT:-$PROJECT_DIR/dist/RC001-Viber.app}"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$PROJECT_DIR"
"$PROJECT_DIR/generate_app_icon.sh"
swift build -c release --product rc001-probe
BIN_DIR="$(swift build -c release --show-bin-path)"

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BIN_DIR/rc001-probe" "$CONTENTS_DIR/MacOS/rc001-probe"
cp "$PROJECT_DIR/Resources/RC001Probe-Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/RC001-Viber.icns" "$CONTENTS_DIR/Resources/RC001-Viber.icns"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
