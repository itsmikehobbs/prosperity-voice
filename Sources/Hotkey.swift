import AppKit
import CoreGraphics

/// Watches the keyboard with a CGEventTap and feeds the Fn gesture state machine.
/// Needs Accessibility permission (it can swallow the latch Space and Esc).
final class Hotkey {
    var onAction: ((GestureAction) -> Void)?
    private(set) var gesture = FnGesture()
    private var tap: CFMachPort?
    private var fnIsDown = false
    private var retryTimer: Timer?

    var isRunning: Bool { tap != nil }

    /// Start the tap, retrying every 2 seconds until Accessibility is granted.
    func start() {
        if install() { return }
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            if self?.install() == true { t.invalidate() }
        }
    }

    func resetGesture() { gesture.reset() }

    private func install() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<Hotkey>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        Log.write("hotkey tap installed")
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let now = ProcessInfo.processInfo.systemUptime
        var gestureEvent: GestureEvent?

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            let down = event.flags.contains(.maskSecondaryFn)
            if down != fnIsDown {
                fnIsDown = down
                gestureEvent = down ? .fnDown(now) : .fnUp(now)
            }
        case .keyDown:
            // Ignore our own synthetic ⌘V and other posted events.
            if event.getIntegerValueField(.eventSourceUserData) == Inserter.syntheticMarker { break }
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 49: gestureEvent = .spaceDown
            case 53: gestureEvent = .escape
            default: gestureEvent = .otherKeyDown(now)
            }
        case .keyUp:
            if event.getIntegerValueField(.keyboardEventKeycode) == 49 { gestureEvent = .spaceUp }
        default:
            break
        }

        guard let gestureEvent else { return Unmanaged.passUnretained(event) }
        let (action, swallow) = gesture.handle(gestureEvent)
        // Act after the key event is handed back. Starting the microphone can be slow, and while
        // this callback runs, every keystroke on the Mac waits (macOS switches the tap off if it's too slow).
        if action != .none {
            DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
        }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }
}
