#!/usr/bin/env bash
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "=========================================="
echo "  📦 Building DMG installer image ...     "
echo "=========================================="

./scripts/package_app.sh

DMG_TMP="/tmp/TeamsWake_dmg_staging"
DMG_OUTPUT="$REPO_ROOT/dist/TeamsWake-2.0.0.dmg"
VOLUME_NAME="Teams Wake Installer"

rm -rf "$DMG_TMP"
mkdir -p "$DMG_TMP"
cp -R "$REPO_ROOT/dist/TeamsWake.app" "$DMG_TMP/"
ln -s /Applications "$DMG_TMP/Applications"

rm -f "$DMG_OUTPUT"

echo "Generating DMG image file..."
hdiutil create -volname "$VOLUME_NAME" \
    -srcfolder "$DMG_TMP" \
    -ov -format UDZO \
    "$DMG_OUTPUT"

rm -rf "$DMG_TMP"

echo "=========================================="
echo "  🎉 DMG installer image build complete!"
echo "  Output file: $DMG_OUTPUT"
echo "=========================================="
