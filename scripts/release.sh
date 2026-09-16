#!/usr/bin/env bash
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# 1. Parse target version (safely fetch latest tag and prompt if missing)
LATEST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v2.0.0")
LATEST_VER="${LATEST_TAG#v}"

TARGET_VER="$1"
if [ -z "$TARGET_VER" ]; then
    if [ -t 0 ]; then
        echo "💡 Current latest release tag: ${LATEST_TAG}"
        read -p "👉 Enter version to release [default: ${LATEST_VER}]: " INPUT_VER
        TARGET_VER="${INPUT_VER:-$LATEST_VER}"
    else
        echo "❌ Error: Version argument is required."
        echo "Usage: ./scripts/release.sh <version>"
        echo "Example: ./scripts/release.sh 2.0.1"
        echo "Current latest release: ${LATEST_TAG}"
        exit 1
    fi
fi

VERSION="${TARGET_VER#v}"
TAG="v${VERSION}"
BUILD_NUMBER=$(echo "$VERSION" | tr -cd '0-9')
if [ -z "$BUILD_NUMBER" ]; then
    BUILD_NUMBER="200"
fi

echo "=========================================="
echo "  🚀 Releasing Teams Wake ${TAG} (Universal 2)"
echo "=========================================="

APP_BUNDLE="$REPO_ROOT/dist/TeamsWake.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "--> Step 1/4: Building Universal 2 binary (arm64 + x86_64)..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

ARM64_OK=0
if swift build -c release --triple arm64-apple-macosx; then
    ARM64_OK=1
fi

X86_OK=0
if swift build -c release --triple x86_64-apple-macosx; then
    X86_OK=1
fi

ARM64_BIN="$REPO_ROOT/.build/arm64-apple-macosx/release/TeamsWake"
X86_BIN="$REPO_ROOT/.build/x86_64-apple-macosx/release/TeamsWake"

if [ "$ARM64_OK" -eq 1 ] && [ "$X86_OK" -eq 1 ] && [ -f "$ARM64_BIN" ] && [ -f "$X86_BIN" ]; then
    echo "    Merging into Universal 2 binary with lipo..."
    lipo -create -output "$MACOS_DIR/TeamsWake" "$ARM64_BIN" "$X86_BIN"
else
    echo "    Fallback: compiling host native architecture..."
    swift build -c release
    cp "$REPO_ROOT/.build/release/TeamsWake" "$MACOS_DIR/TeamsWake"
fi

chmod +x "$MACOS_DIR/TeamsWake"
file "$MACOS_DIR/TeamsWake"

# Copy App Icon
if [ -f "$REPO_ROOT/assets/AppIcon.icns" ]; then
    cp "$REPO_ROOT/assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# Extract Git metadata
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "dev")
GIT_DATE=$(git log -1 --format="%cd" --date=short 2>/dev/null || echo "")
GIT_MSG=$(git log -1 --format="%s" 2>/dev/null | tr -d '"&<>' || echo "")

# Write Info.plist with specified version and git metadata
cat <<EOF > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>TeamsWake</string>
    <key>CFBundleIdentifier</key>
    <string>com.linrol.TeamsWake</string>
    <key>CFBundleName</key>
    <string>TeamsWake</string>
    <key>CFBundleDisplayName</key>
    <string>Teams Wake</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>GitCommit</key>
    <string>${GIT_COMMIT}</string>
    <key>GitCommitDate</key>
    <string>${GIT_DATE}</string>
    <key>GitCommitMessage</key>
    <string>${GIT_MSG}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Clean attributes & sign app bundle
xattr -cr "$APP_BUNDLE"

echo "--> Step 2/4: Signing App Bundle..."
if security find-identity -v -p codesigning | grep -q "Teams Wake Dev"; then
    codesign --force --deep --sign "Teams Wake Dev" "$APP_BUNDLE"
elif security find-identity -v -p codesigning | grep -q "Apple Development"; then
    IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -n 1 | awk -F '"' '{print $2}')
    codesign --force --deep --sign "$IDENTITY" "$APP_BUNDLE"
else
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

# Build DMG installer image
echo "--> Step 3/4: Creating DMG installer image..."
DMG_TMP="/tmp/TeamsWake_dmg_staging"
DMG_OUTPUT="$REPO_ROOT/dist/TeamsWake-${VERSION}.dmg"
VOLUME_NAME="Teams Wake Installer"

rm -rf "$DMG_TMP"
mkdir -p "$DMG_TMP"
cp -R "$APP_BUNDLE" "$DMG_TMP/"
ln -s /Applications "$DMG_TMP/Applications"

xattr -cr "$DMG_TMP"
rm -f "$DMG_OUTPUT"

hdiutil create -volname "$VOLUME_NAME" \
    -srcfolder "$DMG_TMP" \
    -ov -format UDZO \
    "$DMG_OUTPUT"

rm -rf "$DMG_TMP"
xattr -cr "$DMG_OUTPUT"

# Generate version.json for auto-updater
VERSION_JSON="$REPO_ROOT/version.json"
cat <<EOF > "$VERSION_JSON"
{
  "version": "${VERSION}",
  "commit": "${GIT_COMMIT}",
  "date": "${GIT_DATE}",
  "message": "${GIT_MSG}",
  "dmgUrl": "https://github.com/linrol/teams-wake/releases/download/${TAG}/TeamsWake-${VERSION}.dmg"
}
EOF

# Sync Git tag & GitHub Release
echo "--> Step 4/4: Synchronizing Tag & Publishing Release to GitHub..."
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "    Updating existing tag ${TAG}..."
    git tag -f -a "$TAG" -m "Teams Wake ${TAG} - Universal 2 Release"
else
    echo "    Creating new tag ${TAG}..."
    git tag -a "$TAG" -m "Teams Wake ${TAG} - Universal 2 Release"
fi

git push github "$TAG" --force
git push origin "$TAG" --force

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "    Release ${TAG} exists on GitHub. Overwriting assets (--clobber)..."
    gh release upload "$TAG" "$DMG_OUTPUT" "$VERSION_JSON" --clobber
    echo "✅ Successfully overwritten existing release ${TAG}!"
else
    echo "    Release ${TAG} does not exist. Creating new release..."
    gh release create "$TAG" "$DMG_OUTPUT" "$VERSION_JSON" \
        --title "Teams Wake ${TAG} - Universal 2 Release" \
        --generate-notes
    echo "✅ Successfully created new release ${TAG}!"
fi

echo "=========================================="
echo "  🎉 Release ${TAG} Complete!"
echo "  DMG: ${DMG_OUTPUT}"
echo "  URL: https://github.com/linrol/teams-wake/releases/tag/${TAG}"
echo "=========================================="
