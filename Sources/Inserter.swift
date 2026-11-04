import AppKit
import ApplicationServices

/// Puts text on the clipboard and, when a text box has focus, pastes it with ⌘V.
enum Inserter {
    enum Outcome { case pasted, copied }

    /// Tag on our synthetic key events so the hotkey tap ignores them.
    static let syntheticMarker: Int64 = 0x5056_4F49  // "PVOI"

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// App we switched AXEnhancedUserInterface on for, so it can be switched off after pasting.
    private static var wokenPID: pid_t?
    /// How long to keep checking a just-woken Chromium app for its text box before giving up.
    static let wakeWait: Duration = .milliseconds(1500)

    /// Called when recording starts. Electron apps expose their text boxes after
    /// AXManualAccessibility. Chromium apps (Chrome, the ChatGPT app) report no focused element
    /// at all until AXEnhancedUserInterface is set, then need ~2 s (tested 2026-10-09: a plain
    /// query or AXManualAccessibility never woke a fresh Chrome in 12 s; this did in 2.1 s).
    /// Only apps that report nothing get it, since it can slow Chromium down; it's switched off
    /// again after pasting.
    static func prime() {
        guard hasAccessibility, let app = NSWorkspace.shared.frontmostApplication else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .noValue {
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            wokenPID = app.processIdentifier
        }
    }

    private static func releaseWoken() {
        guard let pid = wokenPID else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        wokenPID = nil
    }

    /// Remote-desktop viewers show the other computer as a picture, so there's no text field to
    /// detect. For these, always paste: the viewer syncs the clipboard and forwards ⌘V to the
    /// remote machine. Matched by bundle ID prefix (Jump Desktop, Microsoft Windows App /
    /// Remote Desktop, Apple Screen Sharing).
    static let remoteDesktopPrefixes = ["com.p5sys.jump", "com.microsoft.rdc", "com.apple.ScreenSharing"]
    /// Time for the viewer to send the new clipboard to the remote machine before ⌘V.
    static let remoteClipboardDelay: Duration = .milliseconds(500)

    static func isRemoteDesktop(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return remoteDesktopPrefixes.contains { bundleID.hasPrefix($0) }
    }

    static func insert(_ text: String) async -> Outcome {
        defer { releaseWoken() }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        guard hasAccessibility else { return .copied }
        let front = NSWorkspace.shared.frontmostApplication
        if isRemoteDesktop(front?.bundleIdentifier) {
            try? await Task.sleep(for: remoteClipboardDelay)
            pasteShortcut()
            return .pasted
        }
        var editable = focusedFieldIsEditable()
        // A Chromium app woken at recording start may still be building its accessibility info
        // after a very short dictation: keep checking briefly.
        if !editable, let pid = wokenPID, pid == front?.processIdentifier {
            let clock = ContinuousClock()
            let deadline = clock.now + wakeWait
            while !editable && clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(150))
                editable = focusedFieldIsEditable()
            }
        }
        guard editable else { return .copied }
        pasteShortcut()
        return .pasted
    }

    static func focusedFieldIsEditable() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var focused: CFTypeRef?
        var err = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused)
        if err != .success || focused == nil {
            err = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused)
        }
        guard err == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        return isEditable(focused as! AXUIElement)
    }

    static func describeFocus() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "no app" }
        let woke = wokenPID == app.processIdentifier ? " [woken]" : ""
        return describeFocus(app) + woke
    }

    private static func describeFocus(_ app: NSRunningApplication) -> String {
        if isRemoteDesktop(app.bundleIdentifier) { return "\(app.localizedName ?? "?"): remote desktop (always paste)" }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focused else { return "\(app.localizedName ?? "?"): no focus (\(err.rawValue))" }
        let el = focused as! AXUIElement
        return "\(app.localizedName ?? "?"): role=\(string(el, kAXRoleAttribute) ?? "-") subrole=\(string(el, kAXSubroleAttribute) ?? "-") editable=\(isEditable(el))"
    }

    private static func isEditable(_ el: AXUIElement) -> Bool {
        let role = string(el, kAXRoleAttribute) ?? ""
        let subrole = string(el, kAXSubroleAttribute) ?? ""
        if subrole == "AXSecureTextField" { return false }   // never dictate into password boxes
        if textRoles.contains(role) { return true }
        // Web content (Chrome, Safari, Electron): contenteditable areas report an editable ancestor.
        var ancestor: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, "AXEditableAncestor" as CFString, &ancestor) == .success, ancestor != nil {
            return true
        }
        var settable = DarwinBoolean(false)
        var range: CFTypeRef?
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue,
           AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success {
            return true
        }
        return false
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func pasteShortcut() {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.userData = syntheticMarker
        let vKey: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
