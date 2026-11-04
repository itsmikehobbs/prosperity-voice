import Foundation

/// The AI services that can clean up text. Picks come from head-to-head tests on 2026-09-28
/// (tricky self-corrections, questions, garbled words, misheard names): one model per service.
enum Provider: String, CaseIterable {
    case apple, claude, chatgpt, grok

    var name: String {
        switch self {
        case .apple: return "Apple"
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        case .grok: return "Grok"
        }
    }
    var isCloud: Bool { self != .apple }
    /// Command-line tool that runs the model on the user's own subscription.
    var tool: String? {
        switch self {
        case .apple: return nil
        case .claude: return "claude"
        case .chatgpt: return "codex"
        case .grok: return "grok"
        }
    }
    /// Claude: Sonnet 5.5 at low effort, pinned by exact ID. Beat Sonnet 5, Opus, Haiku 4.5, and
    /// Haiku 5.5 (Haiku 5.5 kept "me and him" and "tomorrow, no wait, Thursday" at every effort level).
    static let claudeModel = "claude-sonnet-5-5"
    /// ChatGPT: Sol 6.1 at low effort, fast tier. 18/18 on the 2026-10-09 tests; medium and high were
    /// no better, only slower, and "none" isn't supported. Needs Codex 0.162+.
    static let chatgptModel = "gpt-6.1-sol"
    /// Grok: 4.7 at low effort through xAI's own `grok` tool (the user's grok.com login), not Cursor.
    /// 18/18 on the 2026-10-09 tests with the steadiest speed (median 6.6 s, slowest 10.9 s).
    static let grokModel = "grok-4.7"
}

/// Which AI cleans up a dictation before it's pasted.
enum CleanupEngine: String, CaseIterable, Identifiable {
    case apple, claude, chatgpt, grok, off
    var id: String { rawValue }
    var provider: Provider? { Provider(rawValue: rawValue) }
    var label: String {
        switch self {
        case .apple: return "Apple (Private Cloud, ~1 sec)"
        case .claude: return "Claude Sonnet 5.5 (~3 sec)"
        case .chatgpt: return "ChatGPT Sol 6.1 (~4 sec)"
        case .grok: return "Grok 4.7 (~7 sec)"
        case .off: return "Off (paste the raw transcript)"
        }
    }
}

/// Which AI handles right-click "Polish with Prosperity Voice".
enum PolishEngine: String, CaseIterable, Identifiable {
    case apple, claude, chatgpt, grok
    var id: String { rawValue }
    var provider: Provider { Provider(rawValue: rawValue)! }
    var label: String {
        switch self {
        case .apple: return "Apple (Private Cloud)"
        case .claude: return "Claude Sonnet 5.5"
        case .chatgpt: return "ChatGPT Sol 6.1"
        case .grok: return "Grok 4.7"
        }
    }
}

/// UserDefaults-backed settings. SwiftUI views use @AppStorage with the same keys.
enum Settings {
    enum Key {
        static let cleanupEngine = "cleanupEngine"
        static let polishEngine = "polishEngine"
        static let customWords = "customWords"
        static let playSounds = "playSounds"
        static let muteWhileRecording = "muteWhileRecording"
        static let keepHistory = "keepHistory"
        static let didFirstLaunch = "didFirstLaunch"
    }

    private static var d: UserDefaults { .standard }

    static var cleanupEngine: CleanupEngine {
        get { CleanupEngine(rawValue: d.string(forKey: Key.cleanupEngine) ?? "") ?? .apple }
        set { d.set(newValue.rawValue, forKey: Key.cleanupEngine) }
    }
    static var polishEngine: PolishEngine {
        PolishEngine(rawValue: d.string(forKey: Key.polishEngine) ?? "") ?? .apple
    }
    static var playSounds: Bool { d.object(forKey: Key.playSounds) as? Bool ?? true }
    static var muteWhileRecording: Bool { d.object(forKey: Key.muteWhileRecording) as? Bool ?? true }
    static var keepHistory: Bool { d.object(forKey: Key.keepHistory) as? Bool ?? true }

    /// Starting list for "Words to spell right": empty. Each person adds their own names in Settings.
    static let defaultWords = ""

    private static var wordsText: String { d.string(forKey: Key.customWords) ?? defaultWords }

    /// Names and brand words (plus the right-hand side of any "heard => meant" fix).
    static var customWords: [String] {
        parseWords(wordsText) + replacements.map(\.to)
    }

    /// "heard => meant" fixes from the same box, applied word-for-word before cleanup.
    static var replacements: [(from: String, to: String)] { parseReplacements(wordsText) }

    private static func items(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func parseWords(_ raw: String) -> [String] {
        items(raw).filter { !$0.contains("=>") }
    }

    static func parseReplacements(_ raw: String) -> [(from: String, to: String)] {
        items(raw).compactMap { item in
            let parts = item.components(separatedBy: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return (parts[0], parts[1])
        }
    }

    /// Whole-word, case-insensitive, one pass over the original text (a fix never feeds another),
    /// longest phrase first.
    static func applyReplacements(_ text: String, _ rules: [(from: String, to: String)]) -> String {
        guard !rules.isEmpty else { return text }
        var map: [String: String] = [:]
        for rule in rules { map[rule.from.lowercased()] = rule.to }   // later rule wins
        let alternation = map.keys.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: "(?<![\\w'])(?:\(alternation))(?![\\w'])", options: [.caseInsensitive]) else {
            return text
        }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            out += map[ns.substring(with: match.range).lowercased()] ?? ns.substring(with: match.range)
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}

/// Where the app keeps its data.
enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Prosperity Voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let recordings: URL = {
        let dir = support.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static var history: URL { support.appendingPathComponent("history.json") }
    static var currentRecording: URL { recordings.appendingPathComponent("current.wav") }
    static var lastRecording: URL { recordings.appendingPathComponent("last.wav") }
    /// Empty working folder for the AI command-line tools, so they never see a project's files.
    static let aiWorkdir: URL = {
        try? FileManager.default.removeItem(at: support.appendingPathComponent("claude-workdir"))  // old name
        let dir = support.appendingPathComponent("ai-workdir", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    /// Scratch files for tool output (outside the AI working folder).
    static let aiOutput: URL = {
        let dir = support.appendingPathComponent("ai-output", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
