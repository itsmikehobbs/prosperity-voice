import Foundation

/// Restarts the app if starting the microphone hangs.
///
/// Seen 2026-11-04: after the displays/dock reconnected, the app's audio connection went stale.
/// The next Fn press asked for the microphone and that call never returned. The app froze, and
/// macOS switched off its Fn listener. A fresh process gets a clean audio connection (tested), so
/// the watchdog relaunches the app and the next Fn press works.
enum MicWatchdog {
    static let restartedKey = "restartedAfterMicHang"
    static let timeout: Double = 6

    private static let lock = NSLock()
    nonisolated(unsafe) private static var armed: UUID?

    /// Call before touching the microphone; pass the token to `disarm` once that returns.
    static func arm(_ what: String) -> UUID {
        let id = UUID()
        lock.withLock { armed = id }
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + timeout) {
            guard lock.withLock({ armed == id }) else { return }
            relaunch(what)
        }
        return id
    }

    static func disarm(_ id: UUID) {
        lock.withLock { if armed == id { armed = nil } }
    }

    /// Runs off the main thread, which is stuck. Launches a fresh copy a second after this one exits.
    private static func relaunch(_ what: String) {
        Log.writeNow("microphone \(what) hung over \(Int(timeout))s; restarting the app")
        UserDefaults.standard.set(true, forKey: restartedKey)
        UserDefaults.standard.synchronize()
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? relaunch.run()
        _exit(0)
    }
}
