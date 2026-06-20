#!/bin/bash
# Build, sign, notarize, staple, package, and publish Flux without Xcode.
#
# One-time prerequisites:
#   brew install create-dmg gh
#   xcrun notarytool store-credentials "Flux" \
#     --apple-id "you@example.com" \
#     --team-id "XXXXXXXXXX" \
#     --password "xxxx-xxxx-xxxx-xxxx"
#
# Usage:
#   CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./release.sh v2.2.0

set -euo pipefail

TAG="${1:?Usage: $0 <version-tag>  e.g. ./release.sh v2.2.0}"
VERSION="${TAG#v}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.rishisinghal.Flux}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-Flux}"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(mktemp -d)"
SWIFT_BUILD_DIR="$BUILD_DIR/swift-build"
APP_DIR="$BUILD_DIR/export/Flux.app"
CONTENTS_DIR="$APP_DIR/Contents"
DMG="$ROOT_DIR/Flux-$TAG.dmg"

cleanup() {
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "✗ Version must be formatted like v2.2.0 or 2.2.0"
    exit 1
fi

if [[ -e "$DMG" ]]; then
    echo "✗ Refusing to overwrite existing $DMG"
    exit 1
fi

for tool in swift create-dmg gh xcrun codesign ditto plutil; do
    if ! command -v "$tool" &>/dev/null; then
        echo "✗ Missing tool: $tool"
        exit 1
    fi
done

if [[ ! -f "$ROOT_DIR/AppIcon.icns" ]]; then
    echo "✗ Missing AppIcon.icns at repository root"
    exit 1
fi

echo "▶ Building Flux $VERSION"
swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$SWIFT_BUILD_DIR" \
    -c release

BIN_DIR="$(swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$SWIFT_BUILD_DIR" \
    -c release \
    --show-bin-path)"

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
ditto "$BIN_DIR/Flux" "$CONTENTS_DIR/MacOS/Flux"
ditto "$ROOT_DIR/Sources/Flux/Info.plist" "$CONTENTS_DIR/Info.plist"
ditto "$ROOT_DIR/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
chmod 755 "$CONTENTS_DIR/MacOS/Flux"

plutil -replace CFBundleIdentifier -string "$BUNDLE_IDENTIFIER" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$CONTENTS_DIR/Info.plist"
if plutil -extract CFBundleExecutable raw "$CONTENTS_DIR/Info.plist" &>/dev/null; then
    plutil -replace CFBundleExecutable -string "Flux" "$CONTENTS_DIR/Info.plist"
else
    plutil -insert CFBundleExecutable -string "Flux" "$CONTENTS_DIR/Info.plist"
fi

if [[ "$(plutil -extract CFBundleIconFile raw "$CONTENTS_DIR/Info.plist")" != "AppIcon" ]]; then
    echo "✗ CFBundleIconFile must be AppIcon"
    exit 1
fi

echo "▶ Signing with $CODESIGN_IDENTITY"
codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$CODESIGN_IDENTITY" \
    "$APP_DIR"

codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "▶ Notarizing app"
ditto -c -k --keepParent "$APP_DIR" "$BUILD_DIR/Flux.zip"
xcrun notarytool submit "$BUILD_DIR/Flux.zip" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"

echo "▶ Creating DMG"
create-dmg \
    --volname "Flux" \
    --volicon "$ROOT_DIR/AppIcon.icns" \
    --window-pos 200 120 \
    --window-size 560 320 \
    --icon-size 100 \
    --icon "Flux.app" 140 160 \
    --hide-extension "Flux.app" \
    --app-drop-link 420 160 \
    --no-internet-enable \
    "$DMG" \
    "$BUILD_DIR/export/"

echo "▶ Notarizing DMG"
xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG"

echo "▶ Publishing GitHub release $TAG"
if git rev-parse --quiet --verify "refs/tags/$TAG" >/dev/null; then
    echo "  (tag already exists, skipping creation)"
else
    git tag "$TAG"
fi
git push origin "$TAG"

gh release create "$TAG" "$DMG" \
    --title "Flux $VERSION" \
    --generate-notes

echo "✓ Done — $(gh release view "$TAG" --json url -q .url)"
