#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-0.3.1}"
DIST_DIR="$ROOT_DIR/dist"
ZIP_PATH="$DIST_DIR/MacDisplay-$VERSION-macOS.zip"

cd "$ROOT_DIR"
MACDISPLAY_VERSION="$VERSION" "$ROOT_DIR/Scripts/package_app.sh"

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$ROOT_DIR/build/MacDisplay.app" "$ZIP_PATH"

echo "Created $ZIP_PATH"
