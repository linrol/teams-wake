#!/usr/bin/env bash
set -euo pipefail

# Removes the local dev build installed by scripts/install.sh.
# Uses the same overridable identifiers, so the release TeamsWake.app is untouched by default.
APP_NAME="${APP_NAME:-TeamsWakeDev}"
BUNDLE_ID="${BUNDLE_ID:-com.linrol.TeamsWake.dev}"

if [ -z "$APP_NAME" ] || [ -z "$BUNDLE_ID" ]; then
    echo "APP_NAME and BUNDLE_ID must not be empty" >&2
    exit 1
fi

APP_DEST="/Applications/$APP_NAME.app"

echo "=========================================="
echo "  🗑  Uninstalling $APP_NAME ($BUNDLE_ID)"
echo "=========================================="

# 1. Terminate running instance
killall "$APP_NAME" 2>/dev/null || true
sleep 0.5

# 2. Remove app bundle
rm -rf "$APP_DEST"

# 3. Remove preferences (flush cfprefsd cache first, then the plist on disk)
defaults delete "$BUNDLE_ID" 2>/dev/null || true
rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist"

# 4. Remove caches and saved window state
rm -rf "$HOME/Library/Caches/$BUNDLE_ID" \
       "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"

# 5. Reset privacy permissions (Accessibility, Microphone, Screen Recording, ...)
tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "=========================================="
echo "  ✅ Removed $APP_DEST"
echo "  ℹ️  If entries remain in System Settings → Privacy & Security,"
echo "     remove them manually with the '−' button."
echo "=========================================="
