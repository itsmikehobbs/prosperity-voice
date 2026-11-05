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
It records first (Record Audio, stop on tap) and then runs Transcribe Audio, because Dictate Text
cut off long dictations. Tested 2026-11-04 on the Mac: Transcribe Audio turned a 4-minute recording
into text in 4 s, and the full chain cleaned a 2-minute, 414-word dictation in 5 s with every item
kept. (Before this date the shortcut was built without its cleanup instructions; fixed.)
`scripts/iphone-shortcut.sh` builds a personal copy on a Mac (the installed app's
`--print-instructions apple`, so it has the user's word list), signs it, and opens it in Shortcuts;
iCloud syncs it to the iPhone. On import over an existing one, Shortcuts asks Replace or Keep Both.
Built by `ios/build_shortcut.py` from `ios/cleanup-instructions.txt`, which is the Mac app's own
Apple cleanup instructions (refresh it with `ProsperityVoice --print-instructions apple`), so both
stay in sync. Cleanup is Apple's "Use Model" action (defaults to Private Cloud
Compute; switch to On-Device in the shortcut for offline use). Tested on the Mac with text input:
~1 sec, passes the self-correction, question, request, garbled-words, and pronoun checks.

### Comparing the cleanup AIs

`ProsperityVoice --bench in.json out.json [words]` runs each dictation through Claude, Apple's cloud
model (the helper shortcut), and Apple's on-device model, with the real instructions, tidy and
guards, and records the output and time. Run 2026-11-04 (macOS 27.2) on 15 dictations (fillers,
self-correction, questions, requests, pronouns, names, "new paragraph", numbers, garbled words,
run-ons, a list, a text reply, 270 words, a prompt injection, casual speech):

| | Claude Sonnet 5.5 | Apple cloud | Apple on-device |
|---|---|---|---|
| Clean, correct | 14 of 15 (1 small miss) | 12 of 15 (2 small misses, 1 empty reply) | 6 of 15 |
| Typical time | 2.2 to 2.6 s (3.7 s long) | 1.1 to 1.4 s (2.5 s long) | 0.5 to 1.2 s (4 s long) |

Claude was the only one to format numbers ($1,250), split the long dictation into paragraphs, and
leave garbled words alone. Apple cloud matched it on everything else and was about twice as fast;
it returned nothing for the prompt-injection test (the app then falls back, and the guard keeps the
raw text). On-device invented words, missed self-corrections and "new paragraph", and answered the
injection; the guard caught 3 of those.

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

## Android version (`android/`)

A keyboard app (Android `InputMethodService`), Kotlin, no UI libraries. Package
`tv.mikehobbs.prosperityvoice`, Android 10+ (minSdk 29), arm64 only.

- Speech: whisper.cpp v1.9.5 (fetched by CMake at build time) through a small JNI bridge
  (`app/src/main/cpp`), model `ggml-base.en` downloaded by the app on first run. Recording is
  chunked like Windows (cut at a pause after 20 s, or at 30 s, transcribed while you talk), so
  there is no time limit. The screen stays on while recording.
- Cleanup: Gemini Nano on the phone (ML Kit GenAI Prompt API, pieces of 250 words), Gemini
  (`gemini-flash-latest`, user's free AI Studio key, with the same "ask again when slow" racing as
  the desktop apps), or Off. Same instructions (`shared/`, packed as assets) and guards.
  Claude and ChatGPT are not offered: a phone app can't use those subscriptions, only paid API keys.
- Build: JDK 17, Android SDK 36, NDK 28.2, CMake 3.31.6. From `android/`:
  `./gradlew testDebugUnitTest assembleDebug` (unit tests: text rules, racing, WAV) and
  `./gradlew connectedDebugAndroidTest` with an emulator running (model download, 2- and 3-minute
  transcription, keyboard typing into a text box, recording start and stop).
- Release: `./gradlew assembleRelease`, signed with `.signing/android-release.keystore` (not in
  git; its passwords are in `android/keystore.properties`, also not in git). Keep that key: an
  update signed with a different key can't install over the old app. Publish the APK as
  `ProsperityVoice.apk` on a GitHub release, so
  https://github.com/itsmikehobbs/prosperity-voice/releases/latest/download/ProsperityVoice.apk
  always points at the newest one. Raise `versionCode` and `versionName` in
  `android/app/build.gradle.kts` for each release.
- Tested 2026-11-04 on an Android 16 emulator (Pixel 9a): 3 min 9 s of speech transcribed in
  13 s (658 of 677 words); the keyboard typed a dictation into a text box. Not tested: a real
  phone, Gemini Nano (needs a supported phone), Gemini cloud cleanup (needs a key).

