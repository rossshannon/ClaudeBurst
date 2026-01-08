#!/bin/bash

# Build script for ClaudeBurst

set -e

cd "$(dirname "$0")"

echo "Building ClaudeBurst..."

xcodebuild -project ClaudeBurst.xcodeproj \
    -scheme ClaudeBurst \
    -configuration Release \
    -derivedDataPath build \
    build

APP_PATH="build/Build/Products/Release/ClaudeBurst.app"

if [ -d "$APP_PATH" ]; then
    echo ""
    echo "Build successful!"
    echo "App location: $APP_PATH"
    echo ""
    echo "To install, run:"
    echo "  cp -r \"$APP_PATH\" /Applications/"
else
    echo "Build failed or app not found"
    exit 1
fi
