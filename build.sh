#!/bin/bash

# Build script for ClaudeBurst

set -e
set -o pipefail

cd "$(dirname "$0")"

INSTALL=false
WATCH=false

for arg in "$@"; do
    case $arg in
        --install|-i) INSTALL=true ;;
        --watch|-w) WATCH=true ;;
    esac
done

build_and_install() {
    echo ""
    echo "=== Building ClaudeBurst... ==="

    # Capture build output to detect failures properly
    BUILD_LOG=$(mktemp)
    if xcodebuild -project ClaudeBurst.xcodeproj \
        -scheme ClaudeBurst \
        -configuration Release \
        -derivedDataPath build \
        clean build > "$BUILD_LOG" 2>&1; then
        # Success - show last 10 lines
        tail -10 "$BUILD_LOG"
        rm -f "$BUILD_LOG"
    else
        # Failure - show full output for debugging
        echo "Build failed! Full output:"
        cat "$BUILD_LOG"
        rm -f "$BUILD_LOG"
        return 1
    fi

    APP_PATH="build/Build/Products/Release/ClaudeBurst.app"

    if [ ! -d "$APP_PATH" ]; then
        echo "Build failed or app not found"
        return 1
    fi

    echo ""
    echo "Build successful!"

    if [ "$INSTALL" = true ]; then
        echo "Installing to /Applications..."
        killall ClaudeBurst 2>/dev/null || true
        sleep 0.5
        rm -rf /Applications/ClaudeBurst.app
        cp -R "$APP_PATH" /Applications/
        echo "Launching..."
        open /Applications/ClaudeBurst.app
        echo "Done!"
    else
        echo "App location: $APP_PATH"
    fi
}

if [ "$WATCH" = true ]; then
    if ! command -v fswatch &> /dev/null; then
        echo "Error: fswatch not found. Install with: brew install fswatch"
        exit 1
    fi

    if [ "$INSTALL" = true ]; then
        echo "Watch mode: will rebuild and install on changes"
    else
        echo "Watch mode: will rebuild on changes (use -i to also install)"
    fi
    echo "Watching: App/, ClaudeBurstCore/ (.swift, .xcassets, .plist, .xib, .storyboard, .entitlements, .strings)"
    echo "Press Ctrl+C to stop"

    # Initial build
    build_and_install

    # Watch for changes - include all relevant file types
    fswatch -o -e "build/" -e ".git/" \
        --include="\.swift$" \
        --include="\.xcassets" \
        --include="\.plist$" \
        --include="\.xib$" \
        --include="\.storyboard$" \
        --include="\.entitlements$" \
        --include="\.strings$" \
        -r App/ ClaudeBurstCore/ | while read; do
        echo ""
        echo "Change detected, rebuilding..."
        build_and_install
    done
else
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
fi
