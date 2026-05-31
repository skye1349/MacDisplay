#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MacDisplay.app"
INSTALL_DIR="${MACDISPLAY_INSTALL_DIR:-$HOME/Applications}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cd "$ROOT_DIR"
pkill -x MacDisplay 2>/dev/null || true
"$ROOT_DIR/Scripts/package_app.sh"

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME"
cp -R "$ROOT_DIR/build/$APP_NAME" "$INSTALL_DIR/$APP_NAME"
xattr -dr com.apple.quarantine "$INSTALL_DIR/$APP_NAME" 2>/dev/null || true
touch "$INSTALL_DIR/$APP_NAME"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$INSTALL_DIR/$APP_NAME" >/dev/null 2>&1 || true
fi

echo "Installed $INSTALL_DIR/$APP_NAME"
echo "Open it with:"
echo "  open \"$INSTALL_DIR/$APP_NAME\""
