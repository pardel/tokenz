#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
build_dir="${TOKENZ_BUILD_DIR:-$PWD/.build}"
iconset="$build_dir/Tokenz.iconset"
mkdir -p "$iconset"
for entry in \
    "16:icon_16x16.png" "32:icon_16x16@2x.png" \
    "32:icon_32x32.png" "64:icon_32x32@2x.png" \
    "128:icon_128x128.png" "256:icon_128x128@2x.png" \
    "256:icon_256x256.png" "512:icon_256x256@2x.png" \
    "512:icon_512x512.png" "1024:icon_512x512@2x.png"; do
    pixels="${entry%%:*}"
    filename="${entry#*:}"
    sips -z "$pixels" "$pixels" Resources/AppIcon.png --out "$iconset/$filename" >/dev/null
done
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
print "Built Resources/AppIcon.icns"
