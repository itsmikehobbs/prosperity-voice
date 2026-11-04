#!/bin/bash
# Installs or updates Prosperity Voice on this Mac by building it here from the source code.
# Safe to run again: running it again updates the app. See INSTALL.md.
#   scripts/install.sh [--cleanup apple|claude|chatgpt|grok|off]
# --cleanup sets which AI cleans up dictation (ask the user first). Without it, a new install picks
# the first of Claude, ChatGPT, Grok that's installed (else Apple), and an update keeps the setting.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "ERROR: $*" >&2; exit 1; }

cleanup=""
if [ "${1:-}" = "--cleanup" ]; then
  cleanup=$(echo "${2:-}" | tr '[:upper:]' '[:lower:]')
  case "$cleanup" in apple|claude|chatgpt|grok|off) ;; *) fail "--cleanup must be apple, claude, chatgpt, grok, or off." ;; esac
fi

echo "==> Checking this Mac"
[ "$(uname -m)" = "arm64" ] || fail "Prosperity Voice needs a Mac with Apple Silicon (M1 or newer)."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 27 ] || fail "Prosperity Voice needs macOS 27 or newer (this Mac has $(sw_vers -productVersion))."
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
  fail "Apple's Command Line Tools are missing. Run: xcode-select --install   (click Install, wait for it to finish, then run this script again)."
fi

echo "==> Building and installing"
scripts/build.sh --install --fast

if [ -n "$cleanup" ]; then
  echo "==> Setting cleanup AI"
  "/Applications/Prosperity Voice.app/Contents/MacOS/ProsperityVoice" --set-cleanup "$cleanup"
  osascript -e 'tell application id "tv.mikehobbs.prosperityvoice" to quit' 2>/dev/null || true
  sleep 1
  pkill -x ProsperityVoice 2>/dev/null || true
  open "/Applications/Prosperity Voice.app"
fi

echo
echo "==> Cleanup AI"
[ -n "$cleanup" ] && echo "Cleanup is set to: $cleanup (change it any time in Settings)."
found=""
for tool in claude codex grok; do
  for c in "$(command -v $tool 2>/dev/null || true)" "$HOME/.local/bin/$tool" "$HOME/.claude/local/$tool" \
           "$HOME/.npm-global/bin/$tool" "$HOME/.grok/bin/$tool" "/opt/homebrew/bin/$tool" "/usr/local/bin/$tool"; do
    [ -n "$c" ] && [ -x "$c" ] && { found="$found $tool"; break; }
  done
done
if [ -n "$cleanup" ]; then
  :
elif [ -n "$found" ]; then
  echo "Found:$found. On first launch Prosperity Voice uses the first of Claude, ChatGPT (codex), Grok"
  echo "that is installed, on your own subscription. Change it any time in Settings."
else
  echo "No Claude, ChatGPT (codex), or Grok tool found. Cleanup uses Apple's free AI on this Mac."
  echo "To use one of those instead, install its tool, log in, and pick it in Prosperity Voice > Settings."
fi

cat <<'MSG'

==> Done. Prosperity Voice is in /Applications and running (waveform icon in the menu bar).
One-time steps only you can do:
  1. When macOS asks, allow Prosperity Voice to use the Microphone.
  2. In System Settings, the Accessibility list: turn on Prosperity Voice. (An AI agent can
     open it with: open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
     (It needs this to see the Fn key and paste. If it's already on but Fn does nothing,
     remove it with the minus button, then add it back.)
Then click in any text box, hold Fn, talk, and let go.
MSG
