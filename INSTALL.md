# Installing Prosperity Voice

Written for AI coding agents (Claude Code, OpenAI Codex, and others), and readable by people. Follow the steps
for the user's computer in order. The app is built on the user's own computer from this source
code, so there is no download to trust and no "unknown developer" warning.

Rules for agents:
- Run each command and read its output before going to the next step. Stop on an error, explain it
  in plain words, and fix it or tell the user what they must do.
- Some steps need the user to click something (permission prompts, installers). Tell them exactly
  what to click, then wait for them to say it's done.
- Don't change system settings, and don't install anything not listed here, without asking.
- Updating is the same steps: they pull the latest code and rebuild. Settings and history are kept.

## Cleanup AI choices

Speech-to-text always runs on the computer. The cleanup step (removing "um"s, fixing punctuation
and self-corrections) uses one AI the user picks, on their own account:

| Choice | Needs | Check it's logged in |
|---|---|---|
| Claude (Sonnet 5.5) | Claude Code (`claude`), Claude subscription | `claude -p "say ok"` prints a short answer |
| ChatGPT (Sol 6.1) | OpenAI Codex CLI (`codex`, 0.162+), ChatGPT plan | `codex login status` says logged in |
| Grok (4.7) | xAI's `grok` CLI, logged in with `grok login` | Settings > Test cleanup AI |
| Apple (Mac only) | Nothing: free, Apple Intelligence | Settings > Test cleanup AI |
| Off | Nothing: pastes the raw transcript | |

**Agents: before installing, ask the user which one they want.** Say which of these tools are
already installed (check with `claude --version`, `codex --version`, `grok --version`), and
recommend one they already have and pay for. If they don't want to use a subscription, recommend
Apple on a Mac (free); on Windows, Off is the only no-subscription choice. Pass their answer to the
install script (`--cleanup <choice>` on Mac, `-Cleanup <choice>` on Windows; choices: `claude`,
`chatgpt`, `grok`, `apple` (Mac only), `off`). If they pick a tool that isn't installed, offer to
install it and help them log in, or pick another. Don't install an AI tool they didn't ask for.

Without a choice, a new install picks the first of Claude, ChatGPT, Grok that is installed; with
none, a Mac uses Apple and Windows pastes uncleaned text. Updates keep the current choice. The user
can switch any time in Settings (menu bar or tray icon > Settings), which also has a
**Test cleanup AI** button.

## Mac

Needs: a Mac with Apple Silicon (M1 or newer) and macOS 27 or newer.

1. **Check the Mac.** Run `uname -m` (must be `arm64`) and `sw_vers -productVersion` (must be 27
   or higher). If not, stop: this Mac can't run Prosperity Voice.
2. **Build tools.** Run `xcode-select -p`. If it fails, run `xcode-select --install`, tell the user
   to click **Install** in the window that opens and wait until it finishes (several minutes), then
   run `xcode-select -p` again.
3. **Get the code.**
   - New install: `git clone https://github.com/itsmikehobbs/prosperity-voice.git ~/prosperity-voice`
   - Update: `cd ~/prosperity-voice && git pull`
4. **Build and install.** `cd ~/prosperity-voice && scripts/install.sh --cleanup <choice>`
   (the user's choice from "Cleanup AI choices"; leave `--cleanup` off for an update).
   It checks the Mac, builds the app, runs its self-test, installs it to `/Applications`, and
   starts it. The first build takes a minute or two. It ends with "Done".
5. **Permissions (the user does these once).** Tell the user:
   - When macOS asks, click **Allow** for the Microphone.
   - Open **System Settings > Privacy & Security > Accessibility** and turn on **Prosperity Voice**.
     It needs this to notice the Fn key and to paste.
   - Open **System Settings > Keyboard** and set **Press Globe (fn) key to** to **Do Nothing**, so macOS
     doesn't open emoji or its own dictation when they hold Fn.
6. **Cleanup AI.** Check the chosen AI is logged in (see "Cleanup AI choices"), and tell the user
   which AI cleans up their text and that they can change it in Settings.
7. **Optional: better Apple cleanup.** If the user wants the free Apple option to be stronger, run
   `open ~/prosperity-voice/ios/"Prosperity Voice Helper.shortcut"` and tell them to click
   **Add Shortcut**. This lets the app use Apple's Private Cloud model. Only matters for Apple.
8. **Test (the user does this; an agent can't).** Tell the user: click in any text box, hold **Fn**, say a sentence, let go. The
   cleaned-up text appears. A waveform icon in the menu bar has Settings and History.

If Fn does nothing: check Accessibility (step 5). If it's already on, remove Prosperity Voice from
that list with the minus button, add it back from `/Applications`, and quit and reopen the app.
The diagnostic log is `~/Library/Application Support/Prosperity Voice/log.txt` (it never holds
what was said).

Uninstall: quit it from the menu bar icon, then
`rm -rf "/Applications/Prosperity Voice.app" ~/Library/Application\ Support/Prosperity\ Voice ~/prosperity-voice`
and `defaults delete tv.mikehobbs.prosperityvoice`. Remove it from Accessibility in System Settings.

## Windows

Needs: 64-bit Windows 10 or 11 and a microphone. Use PowerShell for every command.

After any `winget install`, refresh PATH in the same shell so the new tool is found:
`$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')`

1. **Git.** Run `git --version`. If it's missing:
   `winget install --id Git.Git -e --accept-package-agreements --accept-source-agreements`, then refresh PATH.
2. **Build tools.** Run `dotnet --list-sdks`. If there's no line starting with `9.` (or higher):
   `winget install --id Microsoft.DotNet.SDK.9 -e --accept-package-agreements --accept-source-agreements`,
   then refresh PATH.
3. **Visual C++ runtime** (the speech engine needs it; fresh Windows installs often lack it).
   `winget install --id Microsoft.VCRedist.2015+.x64 -e --accept-package-agreements --accept-source-agreements`
   (if it says it's already installed, that's fine).
4. **Get the code.**
   - New install: `git clone https://github.com/itsmikehobbs/prosperity-voice.git "$HOME\prosperity-voice"`
   - Update: `cd "$HOME\prosperity-voice"; git pull`
5. **Build and install.**
   `cd "$HOME\prosperity-voice"; powershell -ExecutionPolicy Bypass -File windows\install.ps1 -Cleanup <choice>`
   (the user's choice from "Cleanup AI choices"; leave `-Cleanup` off for an update).
   It builds the app (the first build downloads packages and takes a few minutes), downloads the
   speech model (about 150 MB) and runs its self-test, including a speech test. It installs the app
   to `%LOCALAPPDATA%\Programs\Prosperity Voice`, adds a Start menu shortcut, and starts it. It
   starts by itself at login from then on. It ends with "Done". If it stops with an error, the
   message says what to install or fix; do that and run it again.
6. **Cleanup AI.** Check the chosen AI is logged in (see "Cleanup AI choices"), and tell the user
   which AI cleans up their text and that they can change it in Settings.
7. **Check it's running.** `Get-Process ProsperityVoice` should list it. The last `launch` line in
   `$env:APPDATA\Prosperity Voice\log.txt` should say `hotkey=True mic=True`; `mic=False` means
   Windows sees no microphone (plug one in, or check Settings > Privacy > Microphone).
   For a deeper check, `& "$env:LOCALAPPDATA\Programs\Prosperity Voice\ProsperityVoice.exe" --selftest --claude`
   tests speech and Claude cleanup (use `--chatgpt` or `--grok` for those) (quit the app from the tray first, then start it again after).
8. **Test (the user does this; an agent can't).** Tell the user: click in any text box, hold
   **Right Ctrl**, say a sentence, let go. If Windows asks to let Prosperity Voice use the
   microphone, click **Allow**. The tray icon (bottom right, maybe under the ^ arrow) has Settings
   and History.

Uninstall: right-click the tray icon > Quit, then delete `%LOCALAPPDATA%\Programs\Prosperity Voice`,
`%APPDATA%\Prosperity Voice`, `%LOCALAPPDATA%\Prosperity Voice`, the Start menu shortcut, and the
`Prosperity Voice` value under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.

## When you're done

Tell the user, in plain words: it's installed, which key to hold, where the icon is, which AI
cleans up their text, and anything they still need to click.
