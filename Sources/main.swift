import AppKit

let args = CommandLine.arguments
if args.contains("--selftest") {
    Task {
        let cloud = Provider.allCases.filter { $0.isCloud && args.contains("--\($0.rawValue)") }
        let code = await SelfTest.run(cloud: cloud, includeAI: !args.contains("--fast"))
        exit(code)
    }
    dispatchMain()
}
if let i = args.firstIndex(of: "--clean"), args.count > i + 2 {
    // Debug helper: --clean apple|claude "text"
    Task {
        let start = Date()
        do {
            let out = try await Cleaner.run(args[i + 2], mode: .dictation, provider: Provider(rawValue: args[i + 1]) ?? .apple, words: Settings.customWords)
            print(out)
        } catch { print("ERROR: \(error.localizedDescription)") }
        print(String(format: "(%.1fs)", Date().timeIntervalSince(start)))
        exit(0)
    }
    dispatchMain()
}
if let i = args.firstIndex(of: "--transcribe"), args.count > i + 1 {
    // Debug helper: --transcribe file.wav [words,comma,separated]
    Task {
        let words = args.count > i + 2 ? Settings.parseWords(args[i + 2]) : []
        do { print(try await LiveTranscriber.transcribeFile(URL(fileURLWithPath: args[i + 1]), words: words)) }
        catch { print("ERROR: \(error)") }
        exit(0)
    }
    dispatchMain()
}
if let i = args.firstIndex(of: "--export-shared"), args.count > i + 1 {
    // Writes the base cleanup and polish instructions (no word list) for the Windows app.
    let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? Mode.dictation.instructions(words: []).write(to: dir.appendingPathComponent("dictation-instructions.txt"), atomically: true, encoding: .utf8)
    try? Mode.polish.instructions(words: []).write(to: dir.appendingPathComponent("polish-instructions.txt"), atomically: true, encoding: .utf8)
    print("exported to \(dir.path)")
    exit(0)
}
if let i = args.firstIndex(of: "--set-cleanup") {
    // Used by the installer after asking the user: --set-cleanup apple|claude|chatgpt|grok|off
    guard args.count > i + 1, let engine = CleanupEngine(rawValue: args[i + 1].lowercased()) else {
        print("Usage: --set-cleanup apple|claude|chatgpt|grok|off")
        exit(2)
    }
    Settings.cleanupEngine = engine
    UserDefaults.standard.set((PolishEngine(rawValue: engine.rawValue) ?? .apple).rawValue, forKey: Settings.Key.polishEngine)
    UserDefaults.standard.synchronize()
    print("Cleanup set to \(engine.label)")
    exit(0)
}
if args.contains("--print-instructions") {
    // Debug helper: the exact dictation instructions a cloud AI receives (for benchmarking models).
    // Add "apple" for the version Apple's model gets (spelling hint only, no name repair).
    print(Mode.dictation.instructions(words: Settings.customWords, fixNames: !args.contains("apple")))
    exit(0)
}
if args.contains("--probe-focus") {
    // Debug helper: prints what the focused element looks like to the paste logic, every 2 seconds.
    Task {
        for _ in 0..<15 {
            print(Inserter.describeFocus())
            try? await Task.sleep(for: .seconds(2))
        }
        exit(0)
    }
    dispatchMain()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
