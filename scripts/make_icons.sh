#!/bin/bash
# Renders brand/*.svg into Resources/AppIcon.icns and the menu bar template images. Needs Google Chrome (headless).
set -euo pipefail
cd "$(dirname "$0")/.."
CH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

render() { # svg size out
    cat > "$TMP/r.html" <<HTML
<html><body style="margin:0;background:transparent"><img src="file://$PWD/$1" width="$2" height="$2" style="display:block"></body></html>
HTML
    "$CH" --headless --disable-gpu --hide-scrollbars --allow-file-access-from-files --force-device-scale-factor=1 \
        --default-background-color=00000000 --window-size="$2,$2" --screenshot="$3" "file://$TMP/r.html" 2>/dev/null
}

SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
    render brand/app-icon.svg $s "$SET/icon_${s}x${s}.png"
    render brand/app-icon.svg $((s * 2)) "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
render2() { # svg w h out
    cat > "$TMP/r.html" <<HTML
<html><body style="margin:0;background:transparent"><img src="file://$PWD/$1" width="$2" height="$3" style="display:block"></body></html>
HTML
    "$CH" --headless --disable-gpu --hide-scrollbars --allow-file-access-from-files --force-device-scale-factor=1 \
        --default-background-color=00000000 --window-size="$2,$3" --screenshot="$4" "file://$TMP/r.html" 2>/dev/null
}
# Menu bar: a tightly cropped, heavier glyph, 25×18 pt, so it reads at menu bar size.
render2 brand/glyph-menubar.svg 25 18 Resources/MenuIcon.png
render2 brand/glyph-menubar.svg 50 36 Resources/MenuIcon@2x.png
render2 brand/glyph-menubar.svg 75 54 Resources/MenuIcon@3x.png
render brand/app-icon.svg 1024 brand/app-icon-1024.png
echo "Icons written to Resources/"
