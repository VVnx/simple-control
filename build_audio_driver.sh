#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
DRIVER_DIR="$PROJECT_DIR/dist/RC001 Remote Microphone.driver"
CONTENTS_DIR="$DRIVER_DIR/Contents"
EXECUTABLE="$CONTENTS_DIR/MacOS/RC001AudioDriver"

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources/en.lproj"

xcrun clang \
  -std=c11 \
  -O2 \
  -fPIC \
  -bundle \
  -mmacosx-version-min=13.0 \
  -I "$PROJECT_DIR/Sources/RC001SharedAudio/include" \
  "$PROJECT_DIR/Driver/Source/RC001AudioDriver.c" \
  "$PROJECT_DIR/Sources/RC001SharedAudio/RC001SharedAudio.c" \
  -framework CoreAudio \
  -framework CoreFoundation \
  -o "$EXECUTABLE"

cp "$PROJECT_DIR/Driver/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Driver/Resources/en.lproj/Localizable.strings" \
  "$CONTENTS_DIR/Resources/en.lproj/Localizable.strings"

codesign --force --deep --sign - "$DRIVER_DIR"
print "$DRIVER_DIR"
