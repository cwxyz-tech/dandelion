#!/bin/sh
# Builds Dandelion.app. Needs only Apple's free Command Line Tools (no Xcode):
#     xcode-select --install
# Then:  ./build.sh            (Apple Silicon + Intel)
#        ARCHS=arm64 ./build.sh (just Apple Silicon, faster)
set -e
cd "$(dirname "$0")"

ARCHS="${ARCHS:-arm64 x86_64}"
APP="build/Dandelion.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BINS=""
for arch in $ARCHS; do
  echo "== compiling for $arch"
  xcrun swiftc -parse-as-library -O -wmo -swift-version 5 \
    -sdk "$SDK" -target "$arch-apple-macos14.0" -Xlinker -dead_strip \
    Sources/*.swift -o "build/Dandelion-$arch"
  BINS="$BINS build/Dandelion-$arch"
done
# shellcheck disable=SC2086
lipo -create $BINS -output "$APP/Contents/MacOS/Dandelion"
rm -f build/Dandelion-*

cp Info.plist "$APP/Contents/Info.plist"
if [ -f VERSION ]; then
  V="$(tr -d ' \n\r' < VERSION)"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" "$APP/Contents/Info.plist"
fi
iconutil -c icns Icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# ad-hoc signature (required on Apple Silicon, no Apple developer account needed), with the hardened runtime:
# no code injection, no unsigned libraries, no debugger attaching to it
# the one exception it allows: the microphone, for Screen Recorder (macOS still asks you first)
codesign --force --options runtime --timestamp=none --entitlements Dandelion.entitlements --sign - "$APP"
codesign --verify --strict "$APP"

echo ""
echo "Built $APP"
echo "Drag it into your Applications folder, or run:  open \"$APP\""
