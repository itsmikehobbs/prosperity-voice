#!/bin/bash
# Builds the iPhone "Prosperity Voice" shortcut with this Mac's own cleanup instructions (so it
# includes the user's "Words to spell right"), signs it, and opens it in Shortcuts. The user clicks
# Add Shortcut (or Replace). Shortcuts syncs it to their iPhone through iCloud.
# Needs Prosperity Voice installed in /Applications. Run again after changing the word list.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="/Applications/Prosperity Voice.app/Contents/MacOS/ProsperityVoice"
[ -x "$APP" ] || { echo "ERROR: Install Prosperity Voice first (scripts/install.sh)." >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT
"$APP" --print-instructions apple > "$WORK/instructions.txt"
PV_INSTRUCTIONS="$WORK/instructions.txt" PV_OUT="$WORK" TEST_NAME="PV Cleanup Test" python3 ios/build_shortcut.py
OUT_DIR="$HOME/Library/Application Support/Prosperity Voice"
mkdir -p "$OUT_DIR"
shortcuts sign --mode anyone --input "$WORK/Prosperity Voice.wflow" --output "$OUT_DIR/Prosperity Voice.shortcut" 2>/dev/null
open "$OUT_DIR/Prosperity Voice.shortcut"
echo "==> Opened the iPhone shortcut in Shortcuts. Click Add Shortcut (or Replace, if asked)."
echo "It syncs to the iPhone when iCloud sync is on for Shortcuts (iPhone: Settings > Apps > Shortcuts > iCloud Sync)."
echo "On the iPhone: Settings > Action Button > Shortcut > Prosperity Voice."
