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
# Sparkle, for software updates. Inkwell isn't sandboxed, so Sparkle's XPC services aren't needed.
SPARKLE="$(find .build/artifacts -type d -name Sparkle.framework -path '*macos-*' | head -1)"
[ -n "$SPARKLE" ] || { echo "Sparkle.framework not found in .build/artifacts; run swift package resolve." >&2; exit 1; }
ditto "$SPARKLE" $APP/Contents/Frameworks/Sparkle.framework
rm -rf $APP/Contents/Frameworks/Sparkle.framework/XPCServices $APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices
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
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSHumanReadableCopyright</key><string>© 2026 Jaied Al Sabid. MIT License.</string>
<key>SUFeedURL</key><string>https://github.com/jaiedsabid/Inkwell/releases/latest/download/appcast.xml</string>
<key>SUPublicEDKey</key><string>5Y3IRyxg6tWBWf7juKrrMHcM2Arxkxceb8KqhhKMWk4=</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUAllowsAutomaticUpdates</key><false/>
<key>SUScheduledCheckInterval</key><integer>86400</integer>
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
# Sparkle inside out: its helpers, then the framework.
SFW=$APP/Contents/Frameworks/Sparkle.framework/Versions/B
codesign --force --sign "${IDENTITY:--}" $SFW/Autoupdate
codesign --force --sign "${IDENTITY:--}" $SFW/Updater.app
codesign --force --sign "${IDENTITY:--}" $APP/Contents/Frameworks/Sparkle.framework
codesign --force --sign "${IDENTITY:--}" $APP
if [ -n "$IDENTITY" ]; then echo "Signed with the fixed identity $IDENTITY"
else echo "Signed ad hoc: macOS asks for Accessibility again after every build. Run scripts/signing_identity.sh create for a fixed identity." >&2; fi
if [ "${SKIP_DMG:-0}" != "1" ]; then
  rm -rf dist/dmg && mkdir dist/dmg && cp -R $APP dist/dmg/ && ln -s /Applications dist/dmg/Applications
  hdiutil create -volname Inkwell -srcfolder dist/dmg -ov -format UDZO dist/Inkwell.dmg >/dev/null
  rm -rf dist/dmg
fi
echo "Built: $APP (version $VERSION, build $BUILD)"
