#!/bin/bash

# Build script for ClaudeBurst

set -e

cd "$(dirname "$0")"

INSTALL=false
if [ "$1" = "--install" ] || [ "$1" = "-i" ]; then
    INSTALL=true
fi

echo "Cleaning and building ClaudeBurst..."

xcodebuild -project ClaudeBurst.xcodeproj \
    -scheme ClaudeBurst \
    -configuration Release \
    -derivedDataPath build \
    clean build

APP_PATH="build/Build/Products/Release/ClaudeBurst.app"

if [ ! -d "$APP_PATH" ]; then
    echo "Build failed or app not found"
    exit 1
fi

echo ""
echo "Build successful!"
echo "App location: $APP_PATH"

if [ "$INSTALL" = true ]; then
    echo ""
    echo "Installing to /Applications..."
    killall ClaudeBurst 2>/dev/null || true
    sleep 1
    rm -rf /Applications/ClaudeBurst.app
    cp -R "$APP_PATH" /Applications/
    echo "Launching..."
    open /Applications/ClaudeBurst.app
    echo "Done!"
else
    echo ""
    echo "To install, run:"
    echo "  ./build.sh --install"
fi
