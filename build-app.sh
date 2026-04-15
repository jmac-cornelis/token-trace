#!/usr/bin/env bash
set -euo pipefail

APP=TokenTrace.app
PACKAGE_DIR=TokenTrace

swift build -c release --package-path "$PACKAGE_DIR"

BIN=$(find "$PACKAGE_DIR/.build" -name TokenTrace -type f | grep -i release | grep -v dSYM | head -1)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/TokenTrace"
cp "$PACKAGE_DIR/Info.plist" "$APP/Contents/"

xattr -cr "$APP" 2>/dev/null || true

echo "Built: $APP"
echo "Run:   open $APP"
