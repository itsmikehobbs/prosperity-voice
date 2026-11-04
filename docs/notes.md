# Prosperity Voice: Mac developer notes

Design notes, test results, and model choices for the Mac app. For installing, see `../INSTALL.md`.

Originally Mike Hobbs's personal Mac dictation app. Hold **Fn**, talk, let go: cleaned-up text is pasted into
whatever text box is focused. No subscription. Speech-to-text runs on the Mac (Apple's
on-device engine). Cleanup uses Apple's on-device AI by default, or Claude through the
`claude` command-line tool on Mike's subscription.

## Using it

| Do this | What happens |
|---|---|
| Hold **Fn**, talk, let go | Transcribes, cleans up, pastes |
| Hold **Fn**, tap **Space**, let go of both | Hands-free. Tap **Fn** (or click ✓) to finish |
| **Esc** while recording | Cancel (the audio is kept for Retry) |
| Sound playing (a video, music) | Muted while you record, back on when you let go or cancel. Mutes whatever speakers are in use at that moment (Studio Display, laptop, headphones). Turn off in Settings |
| No text box selected | Text goes to the clipboard, press ⌘V |
| Remote desktop in front (Jump Desktop, Windows App, Screen Sharing) | Always pastes: copies, waits half a second for the clipboard to sync, then presses ⌘V on the remote computer. It can't see the remote screen, so make sure a text box is selected over there |
| Highlight text → right-click → **Services → Polish with Prosperity Voice** | Replaces the selection with a polished version |
| Menu bar waveform icon | Start/stop, Retry last recording, switch cleanup AI, History, Settings |

No time limit. Long dictations get cleaned in pieces while you talk, so letting go is fast.

Settings (menu bar icon → Settings…): cleanup AI, polish AI, Claude model, words to spell
right, sounds, mute while recording, open at login, permission status.

### Cleanup AI choices

One model per service, picked from head-to-head tests on 2026-09-28 (self-corrections,
dictated questions, garbled words, misheard names, long dictation, polish):

| Choice | Model | Speed | Runs on |
|---|---|---|---|
| Apple (default) | Apple Private Cloud Compute, on-device as backup | ~1–2 sec | Apple, free, private |
| Claude | Sonnet 5.5, low effort | ~3 sec | Claude subscription (`claude` CLI) |
| ChatGPT | Sol 6.1, low effort, fast tier | ~4 sec | ChatGPT/Codex plan (`codex` CLI) |
| Grok | Grok 4.7, low effort | ~7 sec | Grok subscription (xAI's `grok` CLI, `grok login`) |

Each service has exactly one model; there is no model picker. 2026-10-09 retest: Sol 6.1 low
replaced GPT-6 Sol (18/18 tests; medium/high no better, "none" unsupported; needs Codex 0.162+).
Haiku 5.5 was rejected at every effort level (kept "me and him" and unresolved self-corrections),
and the Haiku option was removed.

Sonnet 5.5 replaced Sonnet 5 on 2026-09-28 (faster on long text, ~11% fewer tokens, never
invented words on garbled audio); it's pinned by exact model ID. Needs Claude Code 2.1.284+.

Rejected in testing: Haiku (slower and reworded meaning), Opus (no better, slower),
GPT-5.6 Sol and GPT-6 Luna (made up words on garbled audio), Grok 4.7 (slower at every level).

The cloud tools run in an empty folder with no tools/files (Claude), a read-only sandbox with
user config skipped (Codex), or read-only "ask" mode with the sandbox on (Cursor). If the chosen
AI fails, cleanup falls back to Apple; if Apple is busy, it falls back to Claude.

**Words to spell right** takes names and brands (comma or line separated). If it keeps
mishearing something, add a fix line like `My Cobbs => Mike Hobbs`. Fix lines are applied
word-for-word before cleanup, every time. Claude also uses the list to repair misheard names on
its own. Apple's AI only uses it for spelling (in testing it swapped ordinary words for names).

## iPhone version (Shortcut)

`ios/Prosperity Voice.shortcut` is a no-install iPhone version: press the Action Button, talk, tap to
stop, and Apple Intelligence cleans it up and copies it to the clipboard (no auto-paste on iPhone).
Built by `ios/build_shortcut.py` from `ios/cleanup-instructions.txt`, which is the Mac app's own
Apple cleanup instructions (refresh it with `ProsperityVoice --print-instructions apple`), so both
stay in sync. Cleanup is Apple's "Use Model" action (defaults to Private Cloud
Compute; switch to On-Device in the shortcut for offline use). Tested on the Mac with text input:
~1 sec, passes the self-correction, question, request, garbled-words, and pronoun checks.

### Apple cleanup on the Mac

Apps can't call Apple's Private Cloud Compute model without a paid developer entitlement
(ModelManager error 1046), but the Shortcuts app can. So the Mac app sends its full prompt to the
`Prosperity Voice Helper` shortcut (`ios/Prosperity Voice Helper.shortcut`, a plain pass-through to
"Use Model: Cloud") with `shortcuts run`. If the helper is missing, offline, or returns nothing, it
uses the on-device model instead. Tested 2026-10-09: the cloud model passed the tricky cases the
on-device model failed (it answered a dictated question and kept "me and him"), and a 1,080-word
dictation took 7 s instead of 19 s. It still edits lightly compared with Sonnet (few paragraphs).

## Where things live

- App: `/Applications/Prosperity Voice.app`
- History: `~/Library/Application Support/Prosperity Voice/history.json`
- Last recording (for Retry): `~/Library/Application Support/Prosperity Voice/Recordings/last.wav`
- Diagnostic log (no transcript text): `~/Library/Application Support/Prosperity Voice/log.txt`

## Rebuilding

Needs macOS 27 on Apple Silicon and the Command Line Tools (full Xcode not required).

```bash
scripts/build.sh            # compile + quick self-test
scripts/build.sh --install  # compile + full self-test + install to /Applications + relaunch
```

Full self-test by hand, including Claude:
`"build/Prosperity Voice.app/Contents/MacOS/ProsperityVoice" --selftest --claude`

Signing uses a local self-signed identity in `.signing/` (gitignored, created on first build)
so macOS keeps the Microphone and Accessibility permissions across rebuilds. If Fn stops
working after an update, remove Prosperity Voice from the Accessibility list in System Settings
and add it back.

Test hooks (simulated keys, window, status) are off by default. Turn on only for testing:
`defaults write tv.mikehobbs.prosperityvoice debugHooks -bool true`, and relaunch.

## Known limits

- US English only.
- Apple's on-device AI has a short burst limit. If it's busy, the app uses Claude instead,
  or pastes the raw transcript if Claude isn't available.
- Apple's AI is lighter on grammar than Claude (it left "Me and him" alone in a test).
  Switch Polish or cleanup to Claude in Settings when you want the stronger edit.
- Some apps don't show the Services menu on right-click (a few Electron apps).
- Chromium-based apps (Chrome, the ChatGPT app) don't report their selected text box until asked
  with AXEnhancedUserInterface, then need ~2 s. The app asks only apps that report nothing, at
  recording start, waits up to 1.5 s more for very short dictations, and switches it off after pasting.
- Speech engine: Apple's general `SpeechTranscriber`. The dictation model (`DictationTranscriber`)
  spelled custom names better but dropped whole phrases on quieter audio, so it was not used.
- If the microphone doesn't start within 6 seconds, the app restarts itself and says so. This
  happened on 2026-11-04: after the displays/dock reconnected, the app's audio connection went
  stale, the next Fn press froze the app, and macOS switched off its Fn listener. A fresh app
  gets a clean audio connection.
- Mute while recording can't mute speakers that macOS itself can't control, like the LG monitor's
  speakers over DisplayPort. It only unmutes what it muted: sound you had muted stays muted. If the
  app quits mid-recording, it unmutes at next launch.
- A recording that never gets louder than -50 dBFS counts as silence (the log shows each
  recording's peak, useful if a quiet mic gets cut off).
