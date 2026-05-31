#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${MACDISPLAY_VERSION:-0.3.1}"
APP_DIR="$ROOT_DIR/build/MacDisplay.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
UNIVERSAL_BIN="$ROOT_DIR/build/universal/MacDisplay"
ICON_SOURCE="$ROOT_DIR/Resources/MacDisplayIcon.png"
ICONSET_DIR="$ROOT_DIR/build/MacDisplay.iconset"

cd "$ROOT_DIR"

APP_BINARY=""

if [[ "${MACDISPLAY_UNIVERSAL:-1}" == "1" ]] && command -v lipo >/dev/null; then
  if swift build -c release --arch arm64 && swift build -c release --arch x86_64; then
    ARM_BUILD_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
    X86_BUILD_DIR="$(swift build -c release --arch x86_64 --show-bin-path)"
    mkdir -p "$(dirname "$UNIVERSAL_BIN")"
    lipo -create "$ARM_BUILD_DIR/MacDisplay" "$X86_BUILD_DIR/MacDisplay" -output "$UNIVERSAL_BIN"
    APP_BINARY="$UNIVERSAL_BIN"
  fi
fi

if [[ -z "$APP_BINARY" ]]; then
  swift build -c release
  BUILD_DIR="$(swift build -c release --show-bin-path)"
  APP_BINARY="$BUILD_DIR/MacDisplay"
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$APP_BINARY" "$MACOS_DIR/MacDisplay"
chmod 755 "$MACOS_DIR/MacDisplay"

if [[ -f "$ICON_SOURCE" ]] && command -v sips >/dev/null && command -v iconutil >/dev/null; then
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"
  sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/MacDisplay.icns"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>MacDisplay</string>
  <key>CFBundleExecutable</key>
  <string>MacDisplay</string>
  <key>CFBundleIconFile</key>
  <string>MacDisplay</string>
  <key>CFBundleIdentifier</key>
  <string>local.macdisplay</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>MacDisplay</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR"

echo "Built $APP_DIR"
file "$MACOS_DIR/MacDisplay"
