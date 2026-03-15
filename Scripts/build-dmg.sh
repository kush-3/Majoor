#!/bin/bash
# build-dmg.sh — Build, sign, notarize, and package Majoor into a DMG
#
# Usage:
#   ./Scripts/build-dmg.sh                      # Build only (no notarization)
#   ./Scripts/build-dmg.sh --notarize           # Build + notarize
#
# Environment variables (required for --notarize):
#   APPLE_ID          — Your Apple ID email
#   APP_PASSWORD      — App-specific password (not your Apple ID password)
#                       Generate at: https://appleid.apple.com/account/manage → App-Specific Passwords
#
# Prerequisites:
#   - Xcode command line tools installed
#   - "Developer ID Application" certificate in Keychain (from Apple Developer Program)
#   - Team ID is auto-detected from the Xcode project

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="Majoor"
SCHEME="Majoor"
PROJECT="Majoor.xcodeproj"
DIST_DIR="$PROJECT_DIR/dist"

# Extract version from project
VERSION=$(grep 'MARKETING_VERSION' "$PROJECT_DIR/$PROJECT/project.pbxproj" | head -1 | sed 's/.*= //;s/;//;s/ //g')
TEAM_ID=$(grep 'DEVELOPMENT_TEAM' "$PROJECT_DIR/$PROJECT/project.pbxproj" | head -1 | sed 's/.*= //;s/;//;s/ //g')
SIGNING_ID="Developer ID Application: ($TEAM_ID)"

echo "=== Majoor Build & Package ==="
echo "Version: $VERSION"
echo "Team ID: $TEAM_ID"
echo ""

# 1. Clean build (Release)
echo "--- Step 1: Clean Release build ---"
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "Using Developer ID for signing"
    xcodebuild clean build \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        CODE_SIGN_IDENTITY="$SIGNING_ID" \
        OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
        2>&1 | tail -5
else
    echo "No Developer ID certificate found — building without code signing"
    xcodebuild clean build \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        CODE_SIGN_IDENTITY="-" \
        2>&1 | tail -5
fi

# Find the built app
BUILD_DIR=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null | grep '^\s*BUILD_DIR' | awk '{print $3}')
APP_PATH="$BUILD_DIR/Release/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Built app not found at $APP_PATH"
    exit 1
fi
echo "Built: $APP_PATH"

# 2. Create dist directory
mkdir -p "$DIST_DIR"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

# Remove old DMG if exists
rm -f "$DMG_PATH"

# 3. Create DMG
echo ""
echo "--- Step 2: Create DMG ---"
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$APP_PATH" \
    -ov -format UDZO \
    "$DMG_PATH"

# 4. Sign DMG
echo ""
echo "--- Step 3: Sign DMG ---"
codesign --sign "$SIGNING_ID" --timestamp "$DMG_PATH" 2>&1 || {
    echo "WARNING: DMG signing failed. You may need a Developer ID certificate."
    echo "The unsigned DMG is still available at: $DMG_PATH"
}

echo ""
echo "DMG created: $DMG_PATH"
echo "Size: $(du -h "$DMG_PATH" | awk '{print $1}')"

# 5. Notarize (optional)
if [[ "${1:-}" == "--notarize" ]]; then
    echo ""
    echo "--- Step 4: Notarize ---"

    if [ -z "${APPLE_ID:-}" ] || [ -z "${APP_PASSWORD:-}" ]; then
        echo "ERROR: --notarize requires APPLE_ID and APP_PASSWORD environment variables."
        echo ""
        echo "  export APPLE_ID='you@example.com'"
        echo "  export APP_PASSWORD='xxxx-xxxx-xxxx-xxxx'  # App-specific password"
        echo ""
        echo "Generate an app-specific password at: https://appleid.apple.com/account/manage"
        exit 1
    fi

    xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait

    echo ""
    echo "--- Step 5: Staple ---"
    xcrun stapler staple "$DMG_PATH"

    echo ""
    echo "Notarized and stapled: $DMG_PATH"
fi

echo ""
echo "=== Done ==="
echo "$APP_NAME $VERSION is ready for distribution: $DMG_PATH"
