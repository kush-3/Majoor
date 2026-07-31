#!/bin/bash
# build-dmg.sh — Build, sign, notarize, and package Majoor into a DMG + Sparkle appcast
#
# Usage:
#   ./Scripts/build-dmg.sh                      # Build + DMG + appcast (no notarization)
#   ./Scripts/build-dmg.sh --notarize           # Build + DMG + notarize + staple + appcast
#
# Environment variables (required for --notarize):
#   APPLE_ID          — Your Apple ID email
#   APP_PASSWORD      — App-specific password (not your Apple ID password)
#                       Generate at: https://appleid.apple.com/account/manage → App-Specific Passwords
#
# Prerequisites:
#   - Xcode command line tools installed
#   - Sparkle EdDSA private key in the login Keychain (see RELEASING.md)
#   - "Developer ID Application" certificate in Keychain (optional; required for --notarize)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="Majoor"
SCHEME="Majoor"
PROJECT="Majoor.xcodeproj"
DIST_DIR="$PROJECT_DIR/dist"

# Read version, build dir, and team from the RELEASE build settings — never grep
# project.pbxproj: the Debug and Release configs each carry their own copy and
# have drifted before (a "1.0.1" DMG once shipped containing a 1.0.0 app).
BUILD_SETTINGS=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null || true)
VERSION=$(echo "$BUILD_SETTINGS" | awk -F' = ' '/^ *MARKETING_VERSION = /{print $2; exit}')
BUILD_DIR=$(echo "$BUILD_SETTINGS" | awk -F' = ' '/^ *BUILD_DIR = /{print $2; exit}')
TEAM_ID=$(echo "$BUILD_SETTINGS" | awk -F' = ' '/^ *DEVELOPMENT_TEAM = /{print $2; exit}')

if [ -z "$VERSION" ] || [ -z "$BUILD_DIR" ]; then
    echo "ERROR: could not read MARKETING_VERSION / BUILD_DIR from xcodebuild -showBuildSettings"
    exit 1
fi

# Resolve a Developer ID identity matching the project's team (empty if none)
SIGNING_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep "($TEAM_ID)" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)

echo "=== Majoor Build & Package ==="
echo "Version: $VERSION"
echo "Team ID: $TEAM_ID"
echo ""

if [[ "${1:-}" == "--notarize" ]] && [ -z "$SIGNING_ID" ]; then
    echo "ERROR: --notarize requires a Developer ID Application certificate for team $TEAM_ID."
    exit 1
fi

# 1. Clean build (Release, universal). The generic destination is required —
# without it xcodebuild pins ARCHS to the local machine's architecture and the
# appcast marks the update Apple-Silicon-only.
echo "--- Step 1: Clean Release build ---"
if [ -n "$SIGNING_ID" ]; then
    echo "Using Developer ID for signing: $SIGNING_ID"
    xcodebuild clean build \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        CODE_SIGN_IDENTITY="$SIGNING_ID" \
        OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
        2>&1 | tail -5
else
    echo "No Developer ID certificate found — building without code signing"
    xcodebuild clean build \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        CODE_SIGN_IDENTITY="-" \
        2>&1 | tail -5
fi

APP_PATH="$BUILD_DIR/Release/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Built app not found at $APP_PATH"
    exit 1
fi
echo "Built: $APP_PATH ($(lipo -archs "$APP_PATH/Contents/MacOS/$APP_NAME"))"

# 2. Create dist directory
mkdir -p "$DIST_DIR"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

# Remove artifacts from previous runs so a mid-run failure can't leave a
# stale appcast that gets published by mistake
rm -f "$DMG_PATH" "$DIST_DIR/appcast.xml"

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
if [ -n "$SIGNING_ID" ]; then
    codesign --sign "$SIGNING_ID" --timestamp "$DMG_PATH" 2>&1 || {
        echo "WARNING: DMG signing failed. The unsigned DMG is still available at: $DMG_PATH"
    }
else
    echo "No Developer ID certificate — skipping DMG signing (Sparkle updates are verified via EdDSA)"
fi

echo ""
echo "DMG created: $DMG_PATH"
echo "Size: $(du -h "$DMG_PATH" | awk '{print $1}')"

# 5. Notarize (optional). Must happen BEFORE the appcast: stapling rewrites the
# DMG, which would invalidate an already-computed EdDSA signature and length.
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
    echo "--- Step 4b: Staple ---"
    xcrun stapler staple "$DMG_PATH"

    echo ""
    echo "Notarized and stapled: $DMG_PATH"
fi

# 6. Generate Sparkle appcast (EdDSA-signed update feed) from the FINAL DMG bytes
echo ""
echo "--- Step 5: Generate appcast ---"
DERIVED_DATA_DIR="$(dirname "$(dirname "$BUILD_DIR")")"
SPARKLE_BIN="$DERIVED_DATA_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin"

if [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
    echo "ERROR: generate_appcast not found at $SPARKLE_BIN"
    echo "Open the project in Xcode once (or run xcodebuild) so SPM downloads the Sparkle artifact bundle."
    exit 1
fi

# Stage only the new DMG so the appcast advertises just this release,
# with enclosure URLs pointing at the matching GitHub release tag.
STAGING_DIR=$(mktemp -d)
trap 'rm -rf "$STAGING_DIR"' EXIT
cp "$DMG_PATH" "$STAGING_DIR/"

"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/kush-3/majoor/releases/download/v$VERSION/" \
    --link "https://github.com/kush-3/majoor/releases" \
    -o "$DIST_DIR/appcast.xml" \
    "$STAGING_DIR" || {
        echo "ERROR: appcast generation failed."
        echo "Most likely cause: the Sparkle EdDSA private key is missing from the login Keychain."
        echo "Do NOT generate a new key — restore the backup instead. See RELEASING.md."
        exit 1
    }

echo "Appcast written: $DIST_DIR/appcast.xml"
echo "Publish it (see RELEASING.md): copy to the majoor-releases repo as appcast.xml and push."

echo ""
echo "=== Done ==="
echo "$APP_NAME $VERSION is ready for distribution: $DMG_PATH"
