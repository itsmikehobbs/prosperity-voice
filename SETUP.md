# Set up Prosperity Voice on your computer

Prosperity Voice lets you talk instead of type. Hold one key, say what you want to write, and let
go. Your words appear in whatever box you're typing in (an email, a chat, a document), with the
"ums" removed and the punctuation fixed.

Your AI assistant installs it for you. It takes about 10 minutes on a Mac and about 15 minutes on
Windows. You only need to click a few things.

On a phone? Skip to [iPhone](#iphone) or [Android](#android). Phones install from a link.

## What you need

- **A computer:**
  - a Mac with Apple Silicon (M1 or newer) and macOS 27 or newer, or
  - a Windows 10 or 11 PC.
- **A microphone.** A laptop's built-in mic works fine.
- **An AI assistant that can work on your computer**, to install the app for you: **Claude Code**
  (the **Code** part of the Claude desktop app) or **Codex** (part of the ChatGPT desktop app). A
  regular chat (or ChatGPT's Work) can't install apps, so it would ask you to type commands
  yourself.
- **An AI to clean up your words.** You pick one during setup:

| Choice | What you need | Cost |
|---|---|---|
| Claude | Claude Code and a Claude plan | Your Claude subscription |
| ChatGPT | Codex and a ChatGPT plan | Your ChatGPT subscription |
| Grok | xAI's grok tool and a Grok plan | Your Grok subscription |
| Apple (Mac only) | Nothing extra | Free |
| Off | Nothing | Free, but your words aren't cleaned up |

## Step 1: Open Claude Code or Codex

You never need to open Terminal or type commands. Your AI does that part.

- **If you use Claude:** open the Claude desktop app and switch from **Chat** to **Code** at the
  top. Don't have the app? Download it from https://claude.com/download and sign in.
- **If you use ChatGPT:** open the ChatGPT desktop app and pick **Codex** from the menu at the top
  left (not Chat or Work). Don't have the app? Download it from https://chatgpt.com/download and
  sign in.

If it asks you to pick a folder, pick your **Documents** folder.

## Step 2: Ask your AI to install Prosperity Voice

Paste this message:

```
Install this for me: https://github.com/itsmikehobbs/prosperity-voice
```

That's all it needs. The page tells your AI how to install it on your kind of computer.

It will ask you **which AI you want to clean up your words** (see the table above). Pick the one
you already pay for, or Apple if you're on a Mac and want it free. You can change it later in
Settings.

If your AI asks for permission to run commands, click **Allow** (or **Yes**). It downloads the
app's code and builds the app on your own computer.

If your AI asks you to open Terminal and paste a command, you're in a regular chat. Go back to
Step 1 and use **Code** (or **Codex** in ChatGPT) instead.

## Step 3: The clicks only you can do

Your AI tells you when, but here's what to expect.

**On a Mac:**
- If a window asks to install "command line developer tools", click **Install** and wait for it
  to finish.
- When macOS asks if Prosperity Voice can use the microphone, click **Allow**.
- Your AI opens **Accessibility** settings for you. Turn on **Prosperity Voice**. This lets it
  notice the key you hold and paste your words.
- Your AI opens **Keyboard** settings. Set **Press Globe (fn) key to** to **Do Nothing**.
- If you picked Apple, click **Add Shortcut** when the Shortcuts app opens.

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
| Holding the key does nothing (Mac) | Click the waveform icon > Settings. Under **Permissions and status**, click the button next to **Accessibility** and turn on Prosperity Voice. If it's already on, remove it with the minus button, add it back, then quit and reopen the app. |
| Holding the key does nothing (Windows) | Make sure the app is running (icon at the bottom right). Start it from the Start menu if not. |
| It says "Copied" instead of pasting | No text box was selected. Click where you want the words and press Cmd+V (Mac) or Ctrl+V (Windows). |
| The words aren't cleaned up | The cleanup AI may be signed out. Open Claude Code or Codex and sign in again, or pick another AI in Settings and click **Test cleanup AI**. |
| Anything else | Paste this into your AI assistant: `Prosperity Voice isn't working right: <describe the problem>. Help me fix it: https://github.com/itsmikehobbs/prosperity-voice` |

## Removing it

Paste this into your AI assistant:

```
Uninstall this for me: https://github.com/itsmikehobbs/prosperity-voice
```

## iPhone

The iPhone version is a Shortcut. It doesn't need an AI assistant or a computer.

**You need:** an iPhone 15 Pro or newer, with Apple Intelligence turned on (Settings > Apple
Intelligence & Siri).

1. On the iPhone, open this link in Safari:
   https://github.com/itsmikehobbs/prosperity-voice/raw/main/ios/Prosperity%20Voice.shortcut
2. Tap the file that downloads. The Shortcuts app opens. Tap **Add Shortcut**.
3. Open **Settings > Action Button**, pick **Shortcut**, and choose **Prosperity Voice**.

**To use it:** press the Action Button and talk. There's no time limit. Tap **Stop** when you're
done. A second or two later your cleaned-up words are copied. Tap in any text box and paste.

The first time, the iPhone asks to let the shortcut use the microphone and speech recognition.
Tap **Allow**.

## Android

The Android version is a keyboard: in any app, switch to the Prosperity Voice keyboard, tap the
mic, talk as long as you like, and tap again. Your cleaned-up words are typed for you. It doesn't
need an AI assistant or a computer.

**You need:** an Android 10 or newer phone, and about 400 MB of free space.

1. On the phone, open this link in Chrome. It downloads the app:
   https://github.com/itsmikehobbs/prosperity-voice/releases/latest/download/ProsperityVoice.apk
2. Tap the downloaded file, then **Install**. If Android asks, allow Chrome to install apps
   (**Settings**, turn on **Allow from this source**, then go back). If Google Play Protect warns
   that it doesn't know the developer, tap **More details**, then **Install anyway**.
3. Open **Prosperity Voice** and follow its three steps: allow the microphone, download the
   speech model (about 150 MB, Wi-Fi recommended), and turn on the keyboard.
4. Pick a cleanup AI in the app:
   - **Gemini Nano**: free, on the phone, for newer phones that have it (recent Pixel and
     Galaxy phones).
   - **Gemini**: free key from Google. The app has a button to get one; paste it in.
   - **Off**: types exactly what you said.

**To use it:** tap in any text box, then switch to the Prosperity Voice keyboard (the keyboard
button at the bottom of the screen). Tap the big blue button and talk. Tap it again when you're
done. Use the keyboard key on the left to switch back to your normal keyboard.

**To update:** open the link again and install. Your settings are kept.

## Privacy and cost

- **Your voice stays on your computer.** It is turned into text there.
- **Only the text goes out**, to the AI you picked to clean it up, on your own account. With Apple, it's handled by Apple Intelligence.
- **Your history is saved only on your computer**, and you can turn it off in Settings.
- **The app is free** for personal, non-commercial use. Cleanup uses the subscription you already have, or Apple's free AI on a Mac.
