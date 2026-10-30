#!/bin/bash
# Builds Morph.app with the Swift compiler that ships with Xcode's Command Line Tools.
#   ./build.sh            build and launch from ./build
#   ./build.sh --install  build, copy to /Applications, and launch
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Morph.app"
ARCH="$(uname -m)"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "✗ swiftc not found. Install the Command Line Tools first:  xcode-select --install"
  exit 1
fi

echo "→ Compiling Morph for $ARCH…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -swift-version 5 -suppress-warnings \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target "$ARCH-apple-macos13.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/Morph"

cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: one 1024px master → every size macOS wants (sips + iconutil are built in).
if [ -f Resources/AppIcon.png ]; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || echo "  (icon skipped)"
fi

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
"$APP/Contents/MacOS/Morph" --selftest || { echo "✗ Self-test failed — not launching this build."; exit 1; }
echo "✓ Built $APP"

pkill -x Morph 2>/dev/null || true
sleep 0.3

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/Morph.app
  cp -R "$APP" /Applications/
  open /Applications/Morph.app
  echo "✓ Installed to /Applications and launched — look for ◌ in the menu bar"
else
  open "$APP"
  echo "✓ Launched — look for ◌ in the menu bar. Hold ⇧ while dragging any file."
fi
