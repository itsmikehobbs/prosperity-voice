import AppKit
import AVFoundation
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var history: HistoryStore!
    private var controller: Controller!
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private let services = ServiceProvider()
    private var phaseWatch: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AudioMuter.restore()   // in case the app quit or restarted while recording
        history = HistoryStore()
        controller = Controller(history: history)
        services.controller = controller
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()

        setUpStatusItem()
        controller.hotkey.start()
        Log.write("launch v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) accessibility=\(Inserter.hasAccessibility) hotkey=\(controller.hotkey.isRunning)")

        if UserDefaults.standard.bool(forKey: MicWatchdog.restartedKey) {
            UserDefaults.standard.removeObject(forKey: MicWatchdog.restartedKey)
            Log.write("restarted after microphone hang")
            controller.panel.flash("The microphone got stuck, so Prosperity Voice restarted. Try again.",
                                   good: false, seconds: 4)
        }

        // Local test hooks, only when turned on with: defaults write tv.mikehobbs.prosperityvoice debugHooks -bool true
        if UserDefaults.standard.bool(forKey: "debugHooks") { installDebugHooks() }

        // First launch: open at login, ask for permissions, show the window.
        let d = UserDefaults.standard
        if !d.bool(forKey: Settings.Key.didFirstLaunch) {
            d.set(true, forKey: Settings.Key.didFirstLaunch)
            // Clean up with an AI the user already has: Claude, then ChatGPT (Codex), then Grok, on
            // their own subscription (stronger edits than Apple's model). With none of them, Apple's
            // free model stays the default. Every choice can be changed in Settings.
            if d.string(forKey: Settings.Key.cleanupEngine) == nil,
               let found = [Provider.claude, .chatgpt, .grok].first(where: { Cleaner.findTool($0) != nil }) {
                d.set(found.rawValue, forKey: Settings.Key.cleanupEngine)
                d.set(found.rawValue, forKey: Settings.Key.polishEngine)
                Log.write("first launch: cleanup set to \(found.name)")
            }
            try? SMAppService.mainApp.register()
            showWindow(tab: 1)
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        if !Inserter.hasAccessibility {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }

        // Warm up the speech model and Apple's language model so the first dictation is quick.
        Task.detached(priority: .utility) {
            try? await LiveTranscriber.prepareModel()
            _ = try? await Cleaner.appleOnDevice("<transcript>\nhello\n</transcript>", instructions: Mode.dictation.instructions(words: []))
        }
    }

    private func installDebugHooks() {
        Log.write("debug hooks enabled")
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("tv.mikehobbs.prosperityvoice.debug.toggle"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.toggle() }
        }
        dnc.addObserver(forName: .init("tv.mikehobbs.prosperityvoice.debug.key"), object: nil, queue: .main) { note in
            // Posts a real keyboard event so tests exercise the actual event tap.
            if let key = note.object as? String { DebugKeys.post(key) }
        }
        dnc.addObserver(forName: .init("tv.mikehobbs.prosperityvoice.debug.window"), object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.showWindow(tab: (note.object as? String) == "settings" ? 1 : 0) }
        }
        dnc.addObserver(forName: .init("tv.mikehobbs.prosperityvoice.debug.hang"), object: nil, queue: .main) { _ in
            // Freezes the main thread like a stuck microphone, to test the watchdog restart.
            _ = MicWatchdog.arm("test")
            Thread.sleep(forTimeInterval: MicWatchdog.timeout + 4)
        }
        dnc.addObserver(forName: .init("tv.mikehobbs.prosperityvoice.debug.status"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.write("status mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) accessibility=\(Inserter.hasAccessibility) hotkey=\(self?.controller.hotkey.isRunning ?? false) focus=[\(Inserter.describeFocus())]")
            }
        }

    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioMuter.restore()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(tab: 0)
        return true
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Prosperity Voice")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        phaseWatch = controller.$phase.sink { [weak self] phase in
            let name = phase == .recording ? "waveform.circle.fill" : (phase == .processing ? "ellipsis.circle" : "waveform")
            self?.statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Prosperity Voice")
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        if !Inserter.hasAccessibility {
            menu.addItem(item("⚠︎ Allow Accessibility to use Fn and auto-paste…", #selector(openSettingsTab)))
            menu.addItem(.separator())
        }
        let hint = NSMenuItem(title: "Hold Fn to talk · Fn+Space for hands-free", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(item(controller.phase == .recording ? "Stop and paste" : "Start recording", #selector(toggleRecording)))
        menu.addItem(item("Retry last recording", #selector(retryLast)))
        menu.addItem(.separator())

        let cleanupMenu = NSMenu()
        for engine in CleanupEngine.allCases {
            let mi = item(engine.label, #selector(pickCleanup(_:)))
            mi.representedObject = engine.rawValue
            mi.state = Settings.cleanupEngine == engine ? .on : .off
            cleanupMenu.addItem(mi)
        }
        let cleanupItem = NSMenuItem(title: "Cleanup", action: nil, keyEquivalent: "")
        cleanupItem.submenu = cleanupMenu
        menu.addItem(cleanupItem)
        menu.addItem(item("History…", #selector(openHistoryTab)))
        menu.addItem(item("Settings…", #selector(openSettingsTab)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Prosperity Voice", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        return mi
    }

    @objc private func toggleRecording() { controller.toggle() }
    @objc private func retryLast() { controller.retryLast() }
    @objc private func pickCleanup(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let engine = CleanupEngine(rawValue: raw) {
            Settings.cleanupEngine = engine
        }
    }
    @objc private func openHistoryTab() { showWindow(tab: 0) }
    @objc private func openSettingsTab() { showWindow(tab: 1) }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Window

    private func showWindow(tab: Int) {
        UserDefaults.standard.set(tab, forKey: "windowTab")
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Prosperity Voice"
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("MainWindow")
            window = w
        }
        window?.contentView = NSHostingView(rootView: MainView(history: history, controller: controller, tab: tab))
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Handles right-click → Services → "Polish with Prosperity Voice".
@MainActor
final class ServiceProvider: NSObject {
    weak var controller: Controller?

    @objc func polishText(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let controller, let text = pboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "No text was selected." as NSString
            return
        }
        // Services are synchronous, so keep the run loop turning (panel updates) until the polish is done.
        var result: String?
        var done = false
        Task { @MainActor in
            result = await controller.polish(text)
            done = true
        }
        let deadline = Date().addingTimeInterval(85)
        while !done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard let result else {
            error.pointee = "Polish didn't finish." as NSString
            return
        }
        pboard.clearContents()
        pboard.setString(result, forType: .string)
    }
}

/// Test-only key events (fn-down, fn-up, space-down, space-up, esc), posted like a real keyboard.
enum DebugKeys {
    static func post(_ key: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        var event: CGEvent?
        switch key {
        case "fn-down":
            event = CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: true)
            event?.type = .flagsChanged
            event?.flags = .maskSecondaryFn
        case "fn-up":
            event = CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: false)
            event?.type = .flagsChanged
            event?.flags = []
        case "space-down": event = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true)
        case "space-up": event = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false)
        case "esc-down": event = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)
        case "esc-up": event = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)
        default: return
        }
        event?.post(tap: .cghidEventTap)
    }
}
