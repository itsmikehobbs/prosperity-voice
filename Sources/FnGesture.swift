import Foundation

/// Keyboard events the gesture cares about.
enum GestureEvent: Equatable {
    case fnDown(TimeInterval)
    case fnUp(TimeInterval)
    case spaceDown
    case spaceUp
    case escape
    case otherKeyDown(TimeInterval)
}

/// What the app should do in response.
enum GestureAction: Equatable {
    case none, start, latch, finish, cancel
}

/// Pure Fn state machine, kept separate from the event tap so it can be tested.
///
/// - Hold Fn: record. Release Fn: finish.
/// - While holding Fn, press Space: hands-free. Release both, keep talking, tap Fn to finish.
/// - Esc while recording: cancel.
/// - A very short Fn tap, or Fn + another key right away (Fn shortcuts), cancels quietly.
struct FnGesture {
    enum State: Equatable {
        case idle
        case holding(since: TimeInterval)
        case latchedFnHeld      // latched, Fn not yet released
        case latched            // hands-free, Fn released
        case finishing          // finished by Fn press; waiting for its release
    }

    static let minHold: TimeInterval = 0.25
    static let comboWindow: TimeInterval = 1.0

    private(set) var state: State = .idle
    /// Swallow the next Space key-up (the one that latched hands-free).
    private var swallowSpaceUp = false

    var isActive: Bool {
        switch state {
        case .holding, .latchedFnHeld, .latched: return true
        default: return false
        }
    }

    /// Called when the app finishes or cancels on its own (panel buttons, errors).
    mutating func reset() {
        switch state {
        case .holding, .latchedFnHeld: state = .finishing   // Fn still physically down
        default: state = .idle
        }
    }

    /// Returns the action and whether to swallow the key event.
    mutating func handle(_ event: GestureEvent) -> (GestureAction, Bool) {
        if event == .spaceUp && swallowSpaceUp {
            swallowSpaceUp = false
            return (.none, true)
        }
        switch (state, event) {
        case (.idle, .fnDown(let t)):
            state = .holding(since: t)
            return (.start, false)

        case (.holding(let t0), .fnUp(let t)):
            state = .idle
            return (t - t0 < Self.minHold ? .cancel : .finish, false)
        case (.holding, .spaceDown):
            state = .latchedFnHeld
            swallowSpaceUp = true
            return (.latch, true)
        case (.holding(let t0), .otherKeyDown(let t)):
            if t - t0 < Self.comboWindow {
                state = .finishing
                return (.cancel, false)
            }
            return (.none, false)
        case (.holding, .escape):
            state = .finishing
            return (.cancel, true)

        case (.latchedFnHeld, .spaceDown):
            return (.none, true)                      // key repeat while latching
        case (.latchedFnHeld, .fnUp):
            state = .latched
            return (.none, false)
        case (.latchedFnHeld, .escape):
            state = .finishing
            return (.cancel, true)

        case (.latched, .fnDown):
            state = .finishing
            return (.finish, false)
        case (.latched, .escape):
            state = .idle
            return (.cancel, true)

        case (.finishing, .fnUp):
            state = .idle
            return (.none, false)
        case (.finishing, .fnDown(let t)):
            // Missed a release somehow; treat as a fresh press.
            state = .holding(since: t)
            return (.start, false)

        default:
            return (.none, false)
        }
    }
}
