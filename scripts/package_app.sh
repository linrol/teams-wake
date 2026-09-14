#!/usr/bin/env bash
set -e

# Get repository root directory
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "=========================================="
echo "  Building TeamsWake (Release Mode) ...  "
echo "=========================================="

swift build -c release

BIN_PATH="$REPO_ROOT/.build/release/TeamsWake"
APP_BUNDLE="$REPO_ROOT/dist/TeamsWake.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "Creating App Bundle at: $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy binary executable
cp "$BIN_PATH" "$MACOS_DIR/TeamsWake"
chmod +x "$MACOS_DIR/TeamsWake"

# Copy App Icon
if [ -f "$REPO_ROOT/assets/AppIcon.icns" ]; then
    cp "$REPO_ROOT/assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# Write Info.plist
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
    <string>2.0.0</string>
    <key>CFBundleVersion</key>
    <string>200</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Code signing (using persistent certificate to maintain TCC accessibility permission across rebuilds/reinstalls)
echo "Signing App Bundle..."
if security find-identity -v -p codesigning | grep -q "Teams Wake Dev"; then
    echo "Found signing identity: Teams Wake Dev"
    codesign --force --deep --sign "Teams Wake Dev" "$APP_BUNDLE"
elif security find-identity -v -p codesigning | grep -q "Apple Development"; then
    IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -n 1 | awk -F '"' '{print $2}')
    echo "Found signing identity: $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" "$APP_BUNDLE"
else
    echo "Using ad-hoc signature (-s -)..."
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "=========================================="
echo "  Build & Packaging Success! 🎉           "
echo "  App Location: $APP_BUNDLE               "
echo "=========================================="
