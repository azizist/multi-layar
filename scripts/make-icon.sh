#!/bin/sh
# ./scripts/make-icon.sh — regenerates Resources/AppIcon.icns from
# Resources/AppIcon.svg. Run it after editing the SVG and commit both; the
# build only copies the .icns, so it needs nothing beyond a stock Mac.
set -eu

cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SET="$WORK/AppIcon.iconset"
mkdir "$SET"

swift scripts/render-icon.swift Resources/AppIcon.svg "$WORK/1024.png"

for size in 16 32 128 256 512; do
	sips -z "$size" "$size" "$WORK/1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
	double=$((size * 2))
	sips -z "$double" "$double" "$WORK/1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
