#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
swift scripts/make-icon.swift "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
cp "$TMP/AppIcon.iconset/icon_256x256@2x.png" Resources/AppIcon.png
rm -rf "$TMP"
echo "wrote Resources/AppIcon.icns"
