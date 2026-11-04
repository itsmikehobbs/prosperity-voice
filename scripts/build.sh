#!/bin/bash
# Build Prosperity Voice. Usage:
#   scripts/build.sh            build + fast self-test
#   scripts/build.sh --install  build, full self-test, install to /Applications, relaunch
#   scripts/build.sh --install --fast  same, with the fast self-test (used by scripts/install.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
APP="build/Prosperity Voice.app"
BIN="$APP/Contents/MacOS/ProsperityVoice"
SDK=$(xcrun --sdk macosx --show-sdk-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/icon.iconset

echo "==> Compiling"
swiftc -O -swift-version 5 -target arm64-apple-macos27.0 -sdk "$SDK" \
  -module-name ProsperityVoice Sources/*.swift -o "$BIN"

cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "==> Icon"
if [ ! -f build/AppIcon.icns ]; then
  swift scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out build/icon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out build/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/icon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing"
[ -f .signing/pv.keychain-db ] || scripts/make-signing-identity.sh
security unlock-keychain -p "$(cat .signing/keychain-password)" "$ROOT/.signing/pv.keychain-db"
codesign --force --sign "Prosperity Voice Local Signing" --keychain "$ROOT/.signing/pv.keychain-db" \
  --identifier tv.mikehobbs.prosperityvoice "$APP"
codesign --verify --strict "$APP"
codesign -dr - "$APP" 2>&1 | grep designated

if [ "${1:-}" = "--install" ]; then
  if [ "${2:-}" = "--fast" ]; then
    echo "==> Self-test (fast)"
    "$BIN" --selftest --fast
  else
    echo "==> Self-test (full)"
    "$BIN" --selftest
  fi
  echo "==> Installing to /Applications"
  osascript -e 'tell application id "tv.mikehobbs.prosperityvoice" to quit' 2>/dev/null || true
  sleep 1
  pkill -x ProsperityVoice 2>/dev/null || true
  rm -rf "/Applications/Prosperity Voice.app"
  ditto "$APP" "/Applications/Prosperity Voice.app"
  /System/Library/CoreServices/pbs -update
  open "/Applications/Prosperity Voice.app"
  echo "Installed and launched."
else
  echo "==> Self-test (fast)"
  "$BIN" --selftest --fast
fi
