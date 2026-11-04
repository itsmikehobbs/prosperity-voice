using System.Diagnostics;
using System.Runtime.InteropServices;

namespace ProsperityVoice;

/// <summary>
/// Global low-level keyboard hook feeding the talk-key gesture (Right Ctrl), plus the polish
/// shortcut (Ctrl+Alt+P). Runs on the UI thread; actions are posted back to it so the hook returns
/// fast (Windows drops slow hooks).
/// </summary>
public sealed class Hotkey : IDisposable
{
    const int WH_KEYBOARD_LL = 13;
    const int WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101, WM_SYSKEYDOWN = 0x0104, WM_SYSKEYUP = 0x0105;
    public const int VK_RCONTROL = 0xA3, VK_SPACE = 0x20, VK_ESCAPE = 0x1B, VK_P = 0x50;
    const int VK_CONTROL = 0x11, VK_MENU = 0x12;

    /// <summary>Tag on our own synthetic key events (paste, copy) so the hook ignores them.</summary>
    public static readonly IntPtr SyntheticMarker = new(0x50564F49);   // "PVOI"

    [StructLayout(LayoutKind.Sequential)]
    struct KBDLLHOOKSTRUCT
    {
        public int vkCode, scanCode, flags, time;
        public IntPtr dwExtraInfo;
    }

    delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll")]
    static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")]
    static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetModuleHandle(string? lpModuleName);
    [DllImport("user32.dll")]
    static extern short GetAsyncKeyState(int vKey);

    readonly HookProc proc;   // kept alive so the GC can't collect the callback
    readonly Control ui;
    IntPtr hook;
    bool talkKeyDown;
    readonly Stopwatch clock = Stopwatch.StartNew();

    public Gesture Gesture { get; } = new();
    public event Action<GestureAction>? OnAction;
    public event Action? OnPolish;
    public bool IsRunning => hook != IntPtr.Zero;

    public Hotkey(Control ui)
    {
        this.ui = ui;
        proc = Callback;
    }

    public void Start()
    {
        if (hook != IntPtr.Zero) return;
        hook = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(null), 0);
        Log.Write(hook != IntPtr.Zero ? "keyboard hook installed" : $"keyboard hook failed ({Marshal.GetLastWin32Error()})");
    }

    public void ResetGesture() => Gesture.Reset();

    IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < 0) return CallNextHookEx(hook, nCode, wParam, lParam);
        var k = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
        if (k.dwExtraInfo == SyntheticMarker) return CallNextHookEx(hook, nCode, wParam, lParam);

        var msg = (int)wParam;
        var down = msg is WM_KEYDOWN or WM_SYSKEYDOWN;
        var up = msg is WM_KEYUP or WM_SYSKEYUP;
        var now = clock.Elapsed.TotalSeconds;
        GestureEvent? e = null;

        switch (k.vkCode)
        {
            case VK_RCONTROL:
                if (down && !talkKeyDown) { talkKeyDown = true; e = new GestureEvent.KeyDown(now); }
                else if (up && talkKeyDown) { talkKeyDown = false; e = new GestureEvent.KeyUp(now); }
                break;
            case VK_SPACE:
                e = down ? new GestureEvent.SpaceDown() : up ? new GestureEvent.SpaceUp() : null;
                break;
            case VK_ESCAPE:
                if (down) e = new GestureEvent.Escape();
                break;
            default:
                if (down)
                {
                    if (k.vkCode == VK_P && Pressed(VK_CONTROL) && Pressed(VK_MENU))
                    {
                        Post(() => OnPolish?.Invoke());
                        if (!talkKeyDown) return new IntPtr(1);   // swallow the P
                    }
                    // Modifier keys aren't "other keys" (Shift while talking is fine).
                    if (k.vkCode is not (0x10 or 0x11 or 0x12 or 0xA0 or 0xA1 or 0xA2 or 0xA4 or 0xA5 or 0x5B or 0x5C))
                        e = new GestureEvent.OtherKeyDown(now);
                }
                break;
        }

        if (e != null)
        {
            var (action, swallow) = Gesture.Handle(e);
            if (action != GestureAction.None) Post(() => OnAction?.Invoke(action));
            if (swallow) return new IntPtr(1);
        }
        return CallNextHookEx(hook, nCode, wParam, lParam);
    }

    static bool Pressed(int vk) => (GetAsyncKeyState(vk) & 0x8000) != 0;

    void Post(Action a)
    {
        if (ui.IsHandleCreated) ui.BeginInvoke(a);
    }

    public void Dispose()
    {
        if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook);
        hook = IntPtr.Zero;
    }
}
