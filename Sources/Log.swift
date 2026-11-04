import Foundation

/// Small diagnostic log at ~/Library/Application Support/Prosperity Voice/log.txt (never holds transcript text).
enum Log {
    private static let queue = DispatchQueue(label: "pv.log")
    static var url: URL { Paths.support.appendingPathComponent("log.txt") }

    static func write(_ message: String) {
        let line = line(message)
        queue.async { append(line) }
    }

    /// Writes before returning. For use just before the app exits.
    static func writeNow(_ message: String) {
        let line = line(message)
        queue.sync { append(line) }
    }

    private static func line(_ message: String) -> String {
        "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    }

    private static func append(_ line: String) {
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
