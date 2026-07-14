#!/usr/bin/env bash
# Build a distributable drag-to-install DMG for Petal.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$ROOT_DIR/dist/Petal.app"
APP_BASENAME="$(basename "$APP_BUNDLE")"
FINAL_DMG="$BUILD_DIR/Petal.dmg"
CREATE_DMG="/usr/local/bin/create-dmg"

mkdir -p "$BUILD_DIR"

# A previous failed or interrupted run must not prevent a clean rebuild.
hdiutil detach "/Volumes/Petal" >/dev/null 2>&1 || true
rm -f "$FINAL_DMG" "$BUILD_DIR"/rw.*.dmg

if [[ ! -x "$CREATE_DMG" ]]; then
    echo "error: create-dmg is not executable at $CREATE_DMG" >&2
    exit 1
fi

bash "$ROOT_DIR/scripts/package_app.sh"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "error: expected app bundle not found at $APP_BUNDLE" >&2
    exit 1
fi

"$CREATE_DMG" \
    --volname "Petal" \
    --window-size 640 400 \
    --icon-size 128 \
    --icon "$APP_BASENAME" 170 200 \
    --app-drop-link 470 200 \
    "$FINAL_DMG" \
    "$APP_BUNDLE"

if [[ ! -f "$FINAL_DMG" ]]; then
    echo "error: create-dmg completed without producing $FINAL_DMG" >&2
    exit 1
fi

echo "$FINAL_DMG"
