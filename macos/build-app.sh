#!/bin/sh
# Builds, signs and installs ~/Applications/Unictrl.app.
# Keep the bundle ID, install path and signing identity stable: macOS ties the Accessibility grant to them.
set -eu

: "${UNICTRL_SIGNING_IDENTITY:?Set UNICTRL_SIGNING_IDENTITY to an Apple Development certificate hash (security find-identity -v -p codesigning)}"

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$here"
swift build -c release --arch arm64 --arch x86_64

bin=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Unictrl
stage="$here/.build/Unictrl.app"
rm -rf "$stage"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
cp "$bin" "$stage/Contents/MacOS/Unictrl"
cp "$here/Info.plist" "$stage/Contents/Info.plist"
icons="$here/../assets/icons/mac"
cp "$icons/Unictrl.icns" "$icons/menubar/UnictrlMenubarTemplate.png" "$icons/menubar/UnictrlMenubarTemplate@2x.png" "$stage/Contents/Resources/"
# macOS 26 and later draw the layered icon (Assets.car, CFBundleIconName); earlier versions use the
# flat Unictrl.icns above (CFBundleIconFile). actool also writes a small fallback .icns, not used.
car=$(mktemp -d)
xcrun actool "$icons/Unictrl.icon" --compile "$car" --platform macosx --minimum-deployment-target 15.0 \
  --app-icon Unictrl --output-partial-info-plist "$car/partial.plist" --errors --warnings >/dev/null
cp "$car/Assets.car" "$stage/Contents/Resources/"
rm -rf "$car"
codesign --force --options runtime --sign "$UNICTRL_SIGNING_IDENTITY" "$stage"
codesign --verify --strict "$stage"

dest="$HOME/Applications/Unictrl.app"
pkill -x Unictrl 2>/dev/null || true
rm -rf "$dest"
ditto "$stage" "$dest"
printf 'Installed %s\n' "$dest"
