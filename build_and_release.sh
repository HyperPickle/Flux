#!/bin/bash

# Flux Build & Release Script
# This script automates the building, signing, and packaging of Flux.

set -e # Exit on error

# Configuration
APP_NAME="Flux"
BUNDLE_ID="com.example.Flux"
DEVELOPER_ID="Developer ID Application: Rishi Singhal (Q542L49V3D)"
TEAM_ID="Q542L49V3D"
APP_BUNDLE="${APP_NAME}.app"
ZIP_FILE="${APP_NAME}.zip"

echo "🚀 Starting build process for ${APP_NAME}..."

# 1. Clean and Build
echo "📦 Building release binary..."
swift build -c release
BINARY_PATH=".build/release/Flux"

# If the above fails or path is different, fallback to default release path
if [ ! -f "$BINARY_PATH" ]; then
    BINARY_PATH=".build/release/Flux"
fi

# 2. Prepare App Bundle
echo "📂 Preparing App Bundle..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
cp "${BINARY_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Ensure Info.plist exists in the bundle
if [ ! -f "Sources/Flux/Info.plist" ]; then
    echo "⚠️ Warning: Sources/Flux/Info.plist not found. Using existing bundle's plist."
else
    cp "Sources/Flux/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
fi

# 3. Sign the App
echo "🧹 Cleaning extended attributes..."
xattr -cr "${APP_BUNDLE}"

echo "✍️ Signing application..."
# Check if the developer identity exists in the keychain
if security find-identity -v -p codesigning | grep -q "${DEVELOPER_ID}"; then
    echo "Found valid Developer ID, signing with: ${DEVELOPER_ID}"
    codesign --force --options runtime --deep --sign "${DEVELOPER_ID}" "${APP_BUNDLE}"
else
    echo "⚠️ Warning: Developer ID not found. Falling back to ad-hoc signing (-)..."
    echo "Note: Ad-hoc signed apps cannot be notarized or distributed easily."
    codesign --force --deep --sign - "${APP_BUNDLE}"
fi

# 4. Create ZIP for Notarization
echo "🤐 Creating ZIP archive..."
rm -f "${ZIP_FILE}"
zip -r "${ZIP_FILE}" "${APP_BUNDLE}"

echo "✅ Build and Signing complete!"
echo "--------------------------------------------------"
echo "NEXT STEPS:"
echo "1. Notarize the app (requires app-specific password from appleid.apple.com):"
echo "   xcrun notarytool submit ${ZIP_FILE} --apple-id \"YOUR_APPLE_ID\" --password \"YOUR_APP_SPECIFIC_PASSWORD\" --team-id ${TEAM_ID} --wait"
echo ""
echo "2. After success, staple the ticket:"
echo "   xcrun stapler staple ${APP_BUNDLE}"
echo ""
echo "3. Re-zip for final distribution:"
echo "   zip -r ${ZIP_FILE} ${APP_BUNDLE}"
echo "--------------------------------------------------"
