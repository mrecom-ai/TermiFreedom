#!/bin/zsh
set -eu
cd "${0:A:h:h}"
ICONSET="$PWD/work/TermiFreedom.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" Assets/TermiFreedom-icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    /usr/bin/sips -z "$double" "$double" Assets/TermiFreedom-icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
python3 scripts/package-icon.py
