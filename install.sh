#!/usr/bin/env bash
set -euo pipefail

REPO="jmac-cornelis/token-trace"
APP_NAME="TokenTrace"
INSTALL_DIR="/Applications"

echo "Installing $APP_NAME..."

TARBALL_URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep '"browser_download_url"' \
  | grep '\.tar\.gz' \
  | head -1 \
  | sed 's/.*"browser_download_url": "\(.*\)"/\1/')

if [ -z "$TARBALL_URL" ]; then
  echo "Error: could not find a release tarball. Check https://github.com/$REPO/releases"
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $TARBALL_URL..."
curl -fsSL "$TARBALL_URL" -o "$TMP/TokenTrace.tar.gz"

echo "Extracting..."
tar -xzf "$TMP/TokenTrace.tar.gz" -C "$TMP"

if [ -d "$INSTALL_DIR/$APP_NAME.app" ]; then
  echo "Removing existing $APP_NAME.app..."
  rm -rf "$INSTALL_DIR/$APP_NAME.app"
fi

echo "Installing to $INSTALL_DIR..."
cp -r "$TMP/$APP_NAME.app" "$INSTALL_DIR/"

xattr -dr com.apple.quarantine "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || true

echo ""
echo "$APP_NAME installed successfully."
echo "Launch it from /Applications or Spotlight."
