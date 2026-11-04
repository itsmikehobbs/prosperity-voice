# Set up Prosperity Voice on your computer

Prosperity Voice lets you talk instead of type. Hold one key, say what you want to write, and let
go. Your words appear in whatever box you're typing in (an email, a chat, a document), with the
"ums" removed and the punctuation fixed.

Your AI assistant installs it for you. It takes about 10 minutes on a Mac and about 15 minutes on
Windows. You only need to click a few things.

## What you need

- **A computer:**
  - a Mac with Apple Silicon (M1 or newer) and macOS 27 or newer, or
  - a Windows 10 or 11 PC.
- **A microphone.** A laptop's built-in mic works fine.
- **An AI assistant that can work on your computer**, to install the app for you. Claude Code
  (from Claude) or Codex (from ChatGPT) both work.
- **An AI to clean up your words.** You pick one during setup:

| Choice | What you need | Cost |
|---|---|---|
| Claude | Claude Code and a Claude plan | Your Claude subscription |
| ChatGPT | Codex and a ChatGPT plan | Your ChatGPT subscription |
| Grok | xAI's grok tool and a Grok plan | Your Grok subscription |
| Apple (Mac only) | Nothing extra | Free |
| Off | Nothing | Free, but your words aren't cleaned up |

## Step 1: Install an AI assistant

If you already use Claude Code or Codex, skip to Step 2.

- **Claude Code:** go to https://claude.com/claude-code, follow the install steps for your
  computer, then open it and sign in with your Claude account.
- **Codex:** go to https://developers.openai.com/codex, follow the install steps for your
  computer, then open it and sign in with your ChatGPT account.

## Step 2: Ask your AI to install Prosperity Voice

Open your AI assistant and paste this message:

```
Install this for me: https://github.com/itsmikehobbs/prosperity-voice
```

That's all it needs. The page tells your AI how to install it on your kind of computer.

It will ask you **which AI you want to clean up your words** (see the table above). Pick the one
you already pay for, or Apple if you're on a Mac and want it free. You can change it later in
Settings.

If your AI asks to run commands, say yes. It downloads the app's code and builds the app on your
own computer.

## Step 3: The clicks only you can do

Your AI tells you when, but here's what to expect.

**On a Mac:**
- If a window asks to install "command line developer tools", click **Install** and wait for it
  to finish.
- When macOS asks if Prosperity Voice can use the microphone, click **Allow**.
- Open **System Settings > Privacy & Security > Accessibility** and turn on **Prosperity Voice**.
  This lets it notice the key you hold and paste your words.
- Open **System Settings > Keyboard** and set **Press Globe (fn) key to** to **Do Nothing**.

**On Windows:**
- If Windows asks "Do you want to allow this app to make changes?" while tools are installing,
  click **Yes**.
- If Windows asks if Prosperity Voice can use the microphone, click **Allow**.

## Step 4: Use it

1. Click in any text box.
2. Hold the talk key, say what you want, and let go:
   - Mac: hold **Fn** (the Globe key, bottom left).
   - Windows: hold **Right Ctrl**.
3. Your cleaned-up words appear a second or two later.

More things you can do:

| To do this | Mac | Windows |
|---|---|---|
| Talk without holding the key | Hold Fn, tap Space, let go. Tap Fn when done | Hold Right Ctrl, tap Space, let go. Tap Right Ctrl when done |
| Cancel | Esc | Esc |
| Clean up text you already typed | Select it, right-click > Services > Polish with Prosperity Voice | Select it, press Ctrl+Alt+P |
| Settings and history | Waveform icon at the top of the screen | Icon at the bottom right (maybe under the ^ arrow) |

**Tip:** in Settings, add names and words it should spell your way under **Words to spell
right** (your name, your company, your products). If it keeps mishearing a word, add a line like
`Clawed => Claude`.

## Updating

Paste this into your AI assistant:

```
Update this for me: https://github.com/itsmikehobbs/prosperity-voice
```

Your settings and history are kept.

## If something isn't working

| Problem | Fix |
|---|---|
| Holding the key does nothing (Mac) | Check System Settings > Privacy & Security > Accessibility. If Prosperity Voice is already on, remove it with the minus button, add it back, then quit and reopen the app. |
| Holding the key does nothing (Windows) | Make sure the app is running (icon at the bottom right). Start it from the Start menu if not. |
| It says "Copied" instead of pasting | No text box was selected. Click where you want the words and press Cmd+V (Mac) or Ctrl+V (Windows). |
| The words aren't cleaned up | The cleanup AI may be signed out. Open Claude Code or Codex and sign in again, or pick another AI in Settings and click **Test cleanup AI**. |
| Anything else | Paste this into your AI assistant: `Prosperity Voice isn't working right: <describe the problem>. Help me fix it: https://github.com/itsmikehobbs/prosperity-voice` |

## Removing it

Paste this into your AI assistant:

```
Uninstall this for me: https://github.com/itsmikehobbs/prosperity-voice
```

## Privacy and cost

- **Your voice stays on your computer.** It is turned into text there.
- **Only the text goes out**, to the AI you picked to clean it up, on your own account. With Apple, it's handled by Apple Intelligence.
- **Your history is saved only on your computer**, and you can turn it off in Settings.
- **The app is free** for personal, non-commercial use. Cleanup uses the subscription you already have, or Apple's free AI on a Mac.
