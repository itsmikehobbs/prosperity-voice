using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Automation;

namespace ProsperityVoice;

/// <summary>Puts text on the clipboard and, when a text box has focus, pastes it with Ctrl+V.</summary>
public static class Inserter
{
    public enum Outcome { Pasted, Copied }

    /// <summary>Remote-desktop viewers show the other computer as a picture, so there's no text box
    /// to detect: always paste there (the viewer syncs the clipboard and forwards Ctrl+V).</summary>
    static readonly HashSet<string> RemoteDesktopProcesses = new(StringComparer.OrdinalIgnoreCase)
        { "mstsc", "msrdc", "Windows365", "JumpDesktop", "Jump Desktop", "vncviewer", "tvnviewer", "AnyDesk", "TeamViewer", "parsecd" };

    /// <summary>Chromium-based apps can take a moment to report their focused text box the first time.</summary>
    static readonly HashSet<string> ChromiumProcesses = new(StringComparer.OrdinalIgnoreCase)
        { "chrome", "msedge", "brave", "opera", "vivaldi", "ChatGPT", "Claude", "Slack", "Code", "Cursor", "Discord", "Teams", "ms-teams" };

    static readonly TimeSpan RemoteClipboardDelay = TimeSpan.FromMilliseconds(500);
    static readonly TimeSpan ChromiumWait = TimeSpan.FromMilliseconds(1500);

    public static async Task<Outcome> Insert(string text)
    {
        SetClipboard(text);
        var app = ForegroundProcessName();
        if (app != null && RemoteDesktopProcesses.Contains(app))
        {
            await Task.Delay(RemoteClipboardDelay);
            PasteShortcut();
            return Outcome.Pasted;
        }
        var editable = await FocusedIsEditable();
        if (!editable && app != null && ChromiumProcesses.Contains(app))
        {
            var deadline = DateTime.UtcNow + ChromiumWait;
            while (!editable && DateTime.UtcNow < deadline)
            {
                await Task.Delay(150);
                editable = await FocusedIsEditable();
            }
        }
        if (!editable) return Outcome.Copied;
        PasteShortcut();
        return Outcome.Pasted;
    }

    public static void SetClipboard(string text)
    {
        for (var i = 0; i < 5; i++)
        {
            try { Clipboard.SetText(text); return; }
            catch (ExternalException) { Thread.Sleep(60); }   // another app has the clipboard open
        }
    }

    /// <summary>UI Automation lookup, bounded so a hung app can't freeze the paste.</summary>
    static async Task<bool> FocusedIsEditable()
    {
        var work = Task.Run(() =>
        {
            try { return IsEditable(AutomationElement.FocusedElement); }
            catch { return false; }
        });
        return await Task.WhenAny(work, Task.Delay(1500)) == work && work.Result;
    }

    static bool IsEditable(AutomationElement? el)
    {
        if (el == null) return false;
        var c = el.Current;
        if (c.IsPassword) return false;   // never dictate into password boxes
        var type = c.ControlType;
        bool? writable = null;
        if (el.TryGetCurrentPattern(ValuePattern.Pattern, out var vp))
            writable = !((ValuePattern)vp).Current.IsReadOnly;
        if (type == ControlType.Edit) return writable ?? true;
        if (type == ControlType.Document) return writable ?? el.TryGetCurrentPattern(TextPattern.Pattern, out _);
        if (type == ControlType.ComboBox) return writable ?? false;
        return writable ?? false;
    }

    public static string DescribeFocus()
    {
        var app = ForegroundProcessName() ?? "?";
        if (RemoteDesktopProcesses.Contains(app)) return $"{app}: remote desktop (always paste)";
        try
        {
            var el = AutomationElement.FocusedElement;
            if (el == null) return $"{app}: no focus";
            return $"{app}: type={el.Current.ControlType.ProgrammaticName.Replace("ControlType.", "")} editable={IsEditable(el)}";
        }
        catch (Exception e) { return $"{app}: no focus ({e.GetType().Name})"; }
    }

    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    public static string? ForegroundProcessName()
    {
        try
        {
            GetWindowThreadProcessId(GetForegroundWindow(), out var pid);
            return pid == 0 ? null : Process.GetProcessById((int)pid).ProcessName;
        }
        catch { return null; }
    }

    // MARK: Synthetic keys

    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public KEYBDINPUT ki; public long pad; }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    const uint INPUT_KEYBOARD = 1, KEYEVENTF_KEYUP = 0x2;
    const ushort VK_CONTROL = 0x11, VK_V = 0x56, VK_C = 0x43;

    static INPUT Key(ushort vk, bool up) => new()
    {
        type = INPUT_KEYBOARD,
        ki = new KEYBDINPUT { wVk = vk, dwFlags = up ? KEYEVENTF_KEYUP : 0, dwExtraInfo = Hotkey.SyntheticMarker },
    };

    static void Chord(ushort vk)
    {
        INPUT[] inputs = [Key(VK_CONTROL, false), Key(vk, false), Key(vk, true), Key(VK_CONTROL, true)];
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    public static void PasteShortcut() => Chord(VK_V);

    public static void CopyShortcut() => Chord(VK_C);

    /// <summary>Test-only: press a key like a real keyboard (no marker, so the hook sees it).</summary>
    public static void SendRawKey(ushort vk, bool up)
    {
        INPUT[] inputs = [new INPUT { type = INPUT_KEYBOARD, ki = new KEYBDINPUT { wVk = vk, dwFlags = up ? KEYEVENTF_KEYUP : 0 } }];
        SendInput(1, inputs, Marshal.SizeOf<INPUT>());
    }
}
