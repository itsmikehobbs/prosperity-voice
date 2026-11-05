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
if let i = args.firstIndex(of: "--bench"), args.count > i + 2 {
    // Debug helper: compare the cleanup AIs on the same dictations.
    //   ProsperityVoice --bench in.json out.json [words]
    // in.json is [{"id": "...", "text": "..."}]. Each text goes through Claude, Apple's cloud model
    // (the helper shortcut), and Apple's on-device model, the same way a dictation does (same
    // instructions, tidy and guards). Pass "words" to use this Mac's Words to spell right.
    // Writes [{"id", "engine", "output", "seconds", "accepted", "error"}].
    let inURL = URL(fileURLWithPath: args[i + 1]), outURL = URL(fileURLWithPath: args[i + 2])
    let words = args.contains("words") ? Settings.customWords : []
    Task {
        let samples = (try? JSONSerialization.jsonObject(with: Data(contentsOf: inURL))) as? [[String: String]] ?? []
        var results: [[String: Any]] = []
        for sample in samples {
            let text = sample["text"] ?? ""
            let engines: [(String, Bool, (String, String) async throws -> String)] = [
                ("claude", true, { p, ins in try await Cleaner.claude(p, instructions: ins) }),
                ("apple-cloud", false, { p, ins in try await Cleaner.appleCloud(ins + "\n\n" + p) }),
                ("apple-device", false, { p, ins in try await Cleaner.appleOnDevice(p, instructions: ins) }),
            ]
            for (name, fixNames, call) in engines {
                let instructions = Mode.dictation.instructions(words: words, fixNames: fixNames)
                let started = Date()
                var row: [String: Any] = ["id": sample["id"] ?? "", "engine": name]
                do {
                    let raw = try await call("<transcript>\(text)</transcript>", instructions)
                    let out = Cleaner.capitalizeFirst(Cleaner.tidy(raw, tag: "transcript"))
                    row["output"] = out
                    row["accepted"] = Mode.dictation.accepts(input: text, output: out)
                        && Cleaner.addedNames(input: text, output: out, allowed: words).isEmpty
                } catch {
                    row["error"] = error.localizedDescription
                    row["accepted"] = false
                }
                row["seconds"] = (Date().timeIntervalSince(started) * 10).rounded() / 10
                results.append(row)
                print("\(sample["id"] ?? "") \(name) \(row["seconds"]!)s accepted=\(row["accepted"]!)")
            }
        }
        try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: outURL)
        exit(0)
    }
    RunLoop.main.run()
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
