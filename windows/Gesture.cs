namespace ProsperityVoice;

/// <summary>Keyboard events the gesture cares about. Times are seconds.</summary>
public abstract record GestureEvent
{
    public sealed record KeyDown(double Time) : GestureEvent;     // talk key (Right Ctrl) pressed
    public sealed record KeyUp(double Time) : GestureEvent;       // talk key released
    public sealed record SpaceDown : GestureEvent;
    public sealed record SpaceUp : GestureEvent;
    public sealed record Escape : GestureEvent;
    public sealed record OtherKeyDown(double Time) : GestureEvent;
}

/// <summary>What the app should do in response.</summary>
public enum GestureAction { None, Start, Latch, Finish, Cancel }

/// <summary>
/// Pure talk-key state machine (port of the Mac FnGesture), kept separate from the keyboard hook so
/// it can be tested. Windows can't see the Fn key, so the talk key is Right Ctrl.
/// - Hold Right Ctrl: record. Release: finish.
/// - While holding, press Space: hands-free. Release both, keep talking. Tap Right Ctrl to finish
///   (it finishes on release, so the Ctrl key is up again before the paste).
/// - Esc while recording: cancel.
/// - A very short tap, or Right Ctrl + another key right away (Ctrl+C and friends), cancels quietly.
/// The hook filters key auto-repeat, so KeyDown only arrives on a real press.
/// </summary>
public sealed class Gesture
{
    public enum State { Idle, Holding, LatchedKeyHeld, Latched, FinishPressed, Finishing }

    public const double MinHold = 0.25;
    public const double ComboWindow = 1.0;

    public State Current { get; private set; } = State.Idle;
    double holdStart;
    bool swallowSpaceUp;

    public bool IsActive => Current is State.Holding or State.LatchedKeyHeld or State.Latched or State.FinishPressed;

    /// <summary>Called when the app finishes or cancels on its own (panel buttons, errors).</summary>
    public void Reset()
    {
        Current = Current switch
        {
            State.Holding or State.LatchedKeyHeld or State.FinishPressed => State.Finishing,  // key still down
            _ => State.Idle,
        };
    }

    /// <summary>Returns the action and whether to swallow the key event.</summary>
    public (GestureAction Action, bool Swallow) Handle(GestureEvent e)
    {
        if (e is GestureEvent.SpaceUp && swallowSpaceUp)
        {
            swallowSpaceUp = false;
            return (GestureAction.None, true);
        }

        switch (Current, e)
        {
            case (State.Idle, GestureEvent.KeyDown d):
                Current = State.Holding;
                holdStart = d.Time;
                return (GestureAction.Start, false);

            case (State.Holding, GestureEvent.KeyUp u):
                Current = State.Idle;
                return (u.Time - holdStart < MinHold ? GestureAction.Cancel : GestureAction.Finish, false);
            case (State.Holding, GestureEvent.SpaceDown):
                Current = State.LatchedKeyHeld;
                swallowSpaceUp = true;
                return (GestureAction.Latch, true);
            case (State.Holding, GestureEvent.OtherKeyDown o):
                if (o.Time - holdStart < ComboWindow)
                {
                    Current = State.Finishing;
                    return (GestureAction.Cancel, false);
                }
                return (GestureAction.None, false);
            case (State.Holding, GestureEvent.Escape):
                Current = State.Finishing;
                return (GestureAction.Cancel, true);

            case (State.LatchedKeyHeld, GestureEvent.SpaceDown):
                return (GestureAction.None, true);   // Space auto-repeat while latching
            case (State.LatchedKeyHeld, GestureEvent.KeyUp):
                Current = State.Latched;
                return (GestureAction.None, false);
            case (State.LatchedKeyHeld, GestureEvent.Escape):
                Current = State.Finishing;
                return (GestureAction.Cancel, true);

            case (State.Latched, GestureEvent.KeyDown):
                Current = State.FinishPressed;
                return (GestureAction.None, false);
            case (State.Latched, GestureEvent.Escape):
                Current = State.Idle;
                return (GestureAction.Cancel, true);

            case (State.FinishPressed, GestureEvent.KeyUp):
                Current = State.Idle;
                return (GestureAction.Finish, false);
            case (State.FinishPressed, GestureEvent.Escape):
                Current = State.Finishing;
                return (GestureAction.Cancel, true);

            case (State.Finishing, GestureEvent.KeyUp):
                Current = State.Idle;
                return (GestureAction.None, false);
            case (State.Finishing, GestureEvent.KeyDown d):
                // Missed a release somehow; treat as a fresh press.
                Current = State.Holding;
                holdStart = d.Time;
                return (GestureAction.Start, false);

            default:
                return (GestureAction.None, false);
        }
    }
}
