#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_ICON="${ROOT_DIR}/icons/claudeburst-appicon.png"
ASSETS_DIR="${ROOT_DIR}/App/Assets.xcassets"
APPICON_DIR="${ASSETS_DIR}/AppIcon.appiconset"
MENUBAR_DIR="${ASSETS_DIR}/MenuBarIcon.imageset"

if [[ ! -f "${SRC_ICON}" ]]; then
  echo "Source icon not found: ${SRC_ICON}" >&2
  exit 1
fi

mkdir -p "${APPICON_DIR}" "${MENUBAR_DIR}"

# App icon sizes (macOS)
sips -z 16 16 "${SRC_ICON}" --out "${APPICON_DIR}/icon_16x16.png" >/dev/null
sips -z 32 32 "${SRC_ICON}" --out "${APPICON_DIR}/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "${SRC_ICON}" --out "${APPICON_DIR}/icon_32x32.png" >/dev/null
sips -z 64 64 "${SRC_ICON}" --out "${APPICON_DIR}/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "${SRC_ICON}" --out "${APPICON_DIR}/icon_128x128.png" >/dev/null
sips -z 256 256 "${SRC_ICON}" --out "${APPICON_DIR}/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "${SRC_ICON}" --out "${APPICON_DIR}/icon_256x256.png" >/dev/null
sips -z 512 512 "${SRC_ICON}" --out "${APPICON_DIR}/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "${SRC_ICON}" --out "${APPICON_DIR}/icon_512x512.png" >/dev/null
sips -z 1024 1024 "${SRC_ICON}" --out "${APPICON_DIR}/icon_512x512@2x.png" >/dev/null

cat <<'JSON' > "${APPICON_DIR}/Contents.json"
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

# Menu bar icon sizes
sips -z 18 18 "${SRC_ICON}" --out "${MENUBAR_DIR}/menubar_18.png" >/dev/null
sips -z 36 36 "${SRC_ICON}" --out "${MENUBAR_DIR}/menubar_18@2x.png" >/dev/null

cat <<'JSON' > "${MENUBAR_DIR}/Contents.json"
{
  "images" : [
    { "filename" : "menubar_18.png", "idiom" : "mac", "scale" : "1x" },
    { "filename" : "menubar_18@2x.png", "idiom" : "mac", "scale" : "2x" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

if [[ ! -f "${ASSETS_DIR}/Contents.json" ]]; then
  cat <<'JSON' > "${ASSETS_DIR}/Contents.json"
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
fi

echo "Updated asset catalogue icons from ${SRC_ICON}"
