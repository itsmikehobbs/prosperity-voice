# Prosperity Voice

Hold a key, talk, let go: your words are cleaned up and pasted into whatever text box you're in.
For Mac and Windows. No subscription to us: speech-to-text runs on your computer, and cleanup uses
the AI you already pay for (Claude, ChatGPT, or Grok), or Apple's free AI on a Mac.

> **AI agents:** if your user gave you this link, they want Prosperity Voice installed (or updated,
> or removed, if they say so). Follow [INSTALL.md](INSTALL.md) step by step for their computer
> (Mac or Windows). Plain-text copy:
> https://raw.githubusercontent.com/itsmikehobbs/prosperity-voice/main/INSTALL.md

## Install

New to this? Follow the step-by-step guide: **[SETUP.md](SETUP.md)**.

Open Claude Code (the **Code** part of the Claude desktop app) or Codex (in the ChatGPT desktop app), and paste the
message below. It does the whole install; you only click Allow on a few permission prompts. It
asks which AI you want for cleanup:

> Install this for me: https://github.com/itsmikehobbs/prosperity-voice

To update later, say the same thing with "Update" instead of "Install". Prefer to do it yourself?
Follow [INSTALL.md](INSTALL.md) by hand.

The app is built on your own computer from this code, so there's nothing to download and trust,
and no "unknown developer" warning.

## Using it

| | Mac | Windows |
|---|---|---|
| Talk | Hold **Fn**, talk, let go | Hold **Right Ctrl**, talk, let go |
| Hands-free | Hold Fn, tap **Space**, let go. Tap Fn to finish | Hold Right Ctrl, tap **Space**, let go. Tap Right Ctrl to finish |
| Cancel | **Esc** | **Esc** |
| Polish selected text | Right-click → Services → Polish with Prosperity Voice | **Ctrl+Alt+P** |
| Settings, History, Retry | Waveform icon in the menu bar | Tray icon (bottom right) |

- No time limit. Long dictations are cleaned in pieces while you talk.
- No text box selected? The text is copied instead; paste it where you want.
- On the Mac, other sound (a video, music) is muted while you talk and comes back when you stop.
- **Words to spell right** (Settings): add names and brands it should spell your way. If it keeps
  mishearing something, add a fix line like `Clawed => Claude`.

## Cleanup AI

| Choice | Needs | Mac | Windows |
|---|---|---|---|
| Claude (Sonnet 5.5) | Claude Code, logged in to your Claude plan | ✓ | ✓ |
| Apple | Nothing (Apple Intelligence) | ✓ (free) | n/a |
| ChatGPT (Sol 6.1) | Codex CLI, logged in to your ChatGPT plan | ✓ | ✓ |
| Grok (4.7) | xAI's `grok` CLI, logged in | ✓ | ✓ |
| Off | Nothing | ✓ | ✓ |

Cleanup removes filler words, fixes punctuation and self-corrections ("Tuesday, no wait,
Thursday" → "Thursday"), and keeps your meaning and wording.

## Privacy

Your voice never leaves your computer: speech-to-text runs locally (Apple's on-device engine on
the Mac, Whisper on Windows). The transcript goes only to the cleanup AI you pick, through that
company's own tool on your account. History is saved only on your computer and can be turned off.

## iPhone

A no-install iPhone version using Apple Intelligence: press the Action Button, talk as long as you
like, tap to stop, and the cleaned-up text is copied. Needs an iPhone 15 Pro or newer with Apple
Intelligence on. Setup steps: [SETUP.md](SETUP.md#iphone).

## License

Free for personal and other non-commercial use under the
[PolyForm Noncommercial License 1.0.0](LICENSE.md). Selling it or using it commercially is not
allowed without permission.

Developer notes: [docs/notes.md](docs/notes.md).
