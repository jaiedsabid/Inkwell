#!/bin/bash
# Builds Inkwell.app (+ Inkwell.dmg) using only Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
scripts/fetch_llama.sh
swift build -c release
VERSION="${INKWELL_VERSION:-$(tr -d ' \n' < VERSION 2>/dev/null || echo 0.0.0)}"
BUILD="${INKWELL_BUILD:-1}"
APP=dist/Inkwell.app
rm -rf dist && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/Inkwell $APP/Contents/MacOS/Inkwell
# The local model engine
mkdir -p $APP/Contents/Frameworks
ditto Vendor/llama.xcframework/macos-arm64_x86_64/llama.framework $APP/Contents/Frameworks/llama.framework
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Inkwell</string>
<key>CFBundleDisplayName</key><string>Inkwell</string>
<key>CFBundleIdentifier</key><string>app.inkwell.mac</string>
<key>CFBundleExecutable</key><string>Inkwell</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
cp Resources/AppIcon.icns Resources/MenuIcon.png Resources/MenuIcon@2x.png Resources/MenuIcon@3x.png $APP/Contents/Resources/
# Sign with the fixed "Inkwell Signing" identity when there is one, so macOS keeps the Accessibility permission across
# builds. Without one the build is ad hoc signed and macOS asks for Accessibility again after every build.
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk 'index($0, "\"Inkwell Signing\"") {print $2; exit}')"
fi
if [ "$IDENTITY" = "-" ]; then IDENTITY=""; fi
codesign --force --sign "${IDENTITY:--}" $APP/Contents/Frameworks/llama.framework
codesign --force --sign "${IDENTITY:--}" $APP
if [ -n "$IDENTITY" ]; then echo "Signed with the fixed identity $IDENTITY"
else echo "Signed ad hoc: macOS asks for Accessibility again after every build. Run scripts/signing_identity.sh create for a fixed identity." >&2; fi
if [ "${SKIP_DMG:-0}" != "1" ]; then
  rm -rf dist/dmg && mkdir dist/dmg && cp -R $APP dist/dmg/ && ln -s /Applications dist/dmg/Applications
  hdiutil create -volname Inkwell -srcfolder dist/dmg -ov -format UDZO dist/Inkwell.dmg >/dev/null
  rm -rf dist/dmg
fi
echo "Built: $APP (version $VERSION, build $BUILD)"
