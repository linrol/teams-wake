#!/usr/bin/env bash
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "=========================================="
echo "  📦 Building & Installing TeamsWake ...  "
echo "=========================================="

# 1. Fast incremental build for host architecture
swift build -c release

BIN_PATH="$REPO_ROOT/.build/release/TeamsWake"
APP_DEST="/Applications/TeamsWake.app"
CONTENTS_DIR="$APP_DEST/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# 2. Terminate currently running instance
killall TeamsWake 2>/dev/null || true
sleep 0.5

# 3. In-place update App Bundle (preserve directory inode to maintain macOS TCC permissions)
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp -f "$BIN_PATH" "$MACOS_DIR/TeamsWake"
chmod +x "$MACOS_DIR/TeamsWake"

if [ -f "$REPO_ROOT/assets/AppIcon.icns" ]; then
    cp "$REPO_ROOT/assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# Determine version and git metadata (default to 'dev' for local development)
VERSION="${1:-dev}"
VERSION="${VERSION#v}"
BUILD_NUMBER="1"

GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "dev")
GIT_DATE=$(git log -1 --format="%cd" --date=short 2>/dev/null || echo "")
GIT_MSG=$(git log -1 --format="%s" 2>/dev/null | tr -d '"&<>' || echo "")

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
    <string>14.4</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Teams Wake requires microphone access to capture and transcribe local voice.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Teams Wake requires Screen &amp; System Audio Recording permission to capture remote meeting audio for real-time transcription.</string>
</dict>
</plist>
EOF

# 4. Clean quarantine attributes before signing
xattr -cr "$APP_DEST"

# 5. Code signing (using persistent certificate to maintain TCC accessibility permission)
echo "Signing /Applications/TeamsWake.app..."
DR_REQ='designated => identifier "com.linrol.TeamsWake"'

if security find-identity -v -p codesigning | grep -q "Teams Wake Dev"; then
    echo "Found signing identity: Teams Wake Dev"
    codesign --force --deep -r="$DR_REQ" --sign "Teams Wake Dev" "$APP_DEST"
elif security find-identity -v -p codesigning | grep -q "Apple Development"; then
    IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -n 1 | awk -F '"' '{print $2}')
    echo "Found signing identity: $IDENTITY"
    codesign --force --deep -r="$DR_REQ" --sign "$IDENTITY" "$APP_DEST"
else
    echo "Using ad-hoc signature (-s -)..."
    codesign --force --deep --sign - "$APP_DEST"
fi

# 6. Ensure clean attributes on installed app
xattr -cr "$APP_DEST"

echo "=========================================="
echo "  🎉 Installed to /Applications/TeamsWake.app"
echo "  🚀 Launching..."
echo "=========================================="

open "$APP_DEST"
