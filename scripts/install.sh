#!/usr/bin/env bash
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "=========================================="
echo "  📦 Building & Installing TeamsWake ...  "
echo "=========================================="

# 1. Fast incremental build for host architecture
swift build -c release

# Local dev build uses a distinct name/bundle id so it can run side-by-side with
# the release TeamsWake.app (separate process, UserDefaults and TCC permissions).
APP_NAME="${APP_NAME:-TeamsWakeDev}"
BUNDLE_ID="${BUNDLE_ID:-com.linrol.TeamsWake.dev}"
DISPLAY_NAME="${DISPLAY_NAME:-Teams Wake Dev}"

BIN_PATH="$REPO_ROOT/.build/release/TeamsWake"
APP_DEST="/Applications/$APP_NAME.app"
CONTENTS_DIR="$APP_DEST/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# 2. Terminate currently running instance
killall "$APP_NAME" 2>/dev/null || true
sleep 0.5

# 3. In-place update App Bundle (preserve directory inode to maintain macOS TCC permissions)
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp -f "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

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
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${DISPLAY_NAME}</string>
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

# 5. Code signing with a persistent certificate so TCC permissions survive rebuilds.
# The default designated requirement pins the certificate, so other binaries can't inherit permissions.
# Self-signed certs are untrusted by default, so don't filter with `find-identity -v`.
echo "Signing $APP_DEST..."
SIGN_IDENTITY="${SIGN_IDENTITY:-TeamsWake Code Signing}"

if security find-identity -p codesigning | grep -qF "\"$SIGN_IDENTITY\""; then
    echo "Found signing identity: $SIGN_IDENTITY"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DEST"
elif security find-identity -v -p codesigning | grep -q "Apple Development"; then
    IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -n 1 | awk -F '"' '{print $2}')
    echo "Found signing identity: $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" "$APP_DEST"
else
    echo "⚠️  No signing identity found; using ad-hoc signature (permissions reset on every install)."
    echo "   Run scripts/create-signing-cert.sh once to fix this."
    codesign --force --deep --sign - "$APP_DEST"
fi

# 6. Ensure clean attributes on installed app
xattr -cr "$APP_DEST"

echo "=========================================="
echo "  🎉 Installed to $APP_DEST"
echo "  🚀 Launching..."
echo "=========================================="

open "$APP_DEST"
