#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
OUTPUT_PATH="$PROJECT_DIR/Resources/RC001-Viber.icns"
ICON_TEMP_DIR="$(mktemp -d '/tmp/rc001-viber-icon.XXXXXX')"
ICONSET_DIR="$ICON_TEMP_DIR/RC001-Viber.iconset"

cleanup() {
  if [[ -n "${ICON_TEMP_DIR:-}" && "$ICON_TEMP_DIR" == /tmp/rc001-viber-icon.* && -d "$ICON_TEMP_DIR" ]]; then
    /bin/rm -R "$ICON_TEMP_DIR"
  fi
}
trap cleanup EXIT

mkdir -p "$ICONSET_DIR"
/usr/bin/swift "$PROJECT_DIR/generate_app_icon.swift" "$ICON_TEMP_DIR/icon-1024.png"

for spec in \
  '16:icon_16x16.png' \
  '32:icon_16x16@2x.png' \
  '32:icon_32x32.png' \
  '64:icon_32x32@2x.png' \
  '128:icon_128x128.png' \
  '256:icon_128x128@2x.png' \
  '256:icon_256x256.png' \
  '512:icon_256x256@2x.png' \
  '512:icon_512x512.png' \
  '1024:icon_512x512@2x.png'; do
  dimension="${spec%%:*}"
  filename="${spec#*:}"
  /usr/bin/sips -z "$dimension" "$dimension" "$ICON_TEMP_DIR/icon-1024.png" \
    --out "$ICONSET_DIR/$filename" >/dev/null
done

/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_PATH"
print "$OUTPUT_PATH"
