#!/usr/bin/env bash
# Builds dist/Binary.app from the Swift package (no Xcode project needed).
#   UNIVERSAL=1 scripts/build-app.sh   # arm64 + x86_64
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(cd .. && pwd)
OUT=${OUT:-$ROOT/dist}
APP="$OUT/Binary.app"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR=$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)

if [[ ! -f Resources/AppIcon.icns ]]; then
  scripts/make-icon.sh || echo "warning: icon generation failed, continuing without icon"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Binary" "$APP/Contents/MacOS/Binary"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# UI translations, keyed by the English text (see tr() in Theme.swift).
cp Resources/zh-Hans.json "$APP/Contents/Resources/zh-Hans.json"
# Bundle the server too, so one download covers a Mac that is both client and server.
if [[ -x "$OUT/binaryd" ]]; then
  cp "$OUT/binaryd" "$APP/Contents/Resources/binaryd"
fi
codesign --force --deep --sign - "$APP" >/dev/null
echo "built $APP"
