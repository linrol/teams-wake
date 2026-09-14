#!/usr/bin/env bash
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "=========================================="
echo "  📦 Building and packaging TeamsWake ... "
echo "=========================================="
./scripts/package_app.sh

APP_SRC="$REPO_ROOT/dist/TeamsWake.app"
APP_DEST="/Applications/TeamsWake.app"

echo "=========================================="
echo "  🚀 Installing to /Applications ...     "
echo "=========================================="

# Terminate running instance
killall TeamsWake 2>/dev/null || true
sleep 0.5

# Remove older version and copy newest build
rm -rf "$APP_DEST"
cp -R "$APP_SRC" "$APP_DEST"

# Sign /Applications/TeamsWake.app with persistent certificate
if security find-identity -v -p codesigning | grep -q "Teams Wake Dev"; then
    echo "Signing /Applications/TeamsWake.app with [Teams Wake Dev] identity..."
    codesign --force --deep --sign "Teams Wake Dev" "$APP_DEST"
elif security find-identity -v -p codesigning | grep -q "Apple Development"; then
    IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -n 1 | awk -F '"' '{print $2}')
    codesign --force --deep --sign "$IDENTITY" "$APP_DEST"
else
    codesign --force --deep --sign - "$APP_DEST"
fi

echo "=========================================="
echo "  🎉 Installation Successful!"
echo "  Location: $APP_DEST"
echo "  You can now launch it via Launchpad or Spotlight (⌘ + Space)!"
echo "=========================================="

# Launch installed application
open "$APP_DEST"
