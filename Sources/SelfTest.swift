import Foundation

/// Headless checks: `ProsperityVoice --selftest [--fast] [--claude]`
enum SelfTest {
    nonisolated(unsafe) static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : " — " + detail))
        if !ok { failures += 1 }
    }

    static func run(cloud: [Provider], includeAI: Bool) async -> Int32 {
        gestureTests()
        chunkTests()
        guardTests()
        await historyTests()
        await hedgeTests()
        if includeAI {
            await speechTests()
            await cleanupTests(provider: .apple)
        }
        for provider in cloud {
            await cleanupTests(provider: provider)
            await hedgeLiveTest(provider: provider)
        }
        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    // MARK: Gesture

    static func gestureTests() {
        var g = FnGesture()
        check("hold: Fn down starts", g.handle(.fnDown(0)) == (.start, false))
        check("hold: Fn up finishes", g.handle(.fnUp(2)) == (.finish, false))
        check("hold: back to idle", g.state == .idle)

        g = FnGesture()
        _ = g.handle(.fnDown(0))
        check("tap: short tap cancels", g.handle(.fnUp(0.1)).0 == .cancel)

        g = FnGesture()
        _ = g.handle(.fnDown(0))
        check("latch: Space latches and is swallowed", g.handle(.spaceDown) == (.latch, true))
        check("latch: Space repeat swallowed", g.handle(.spaceDown) == (.none, true))
        check("latch: Fn release keeps recording", g.handle(.fnUp(1)) == (.none, false))
        check("latch: Space release swallowed", g.handle(.spaceUp) == (.none, true))
        check("latch: typing Space later passes through", g.handle(.spaceDown) == (.none, false))
        check("latch: next Fn press finishes", g.handle(.fnDown(5)).0 == .finish)
        check("latch: its release is ignored", g.handle(.fnUp(5.1)).0 == .none)
        check("latch: idle again", g.state == .idle)

        g = FnGesture()
        _ = g.handle(.fnDown(0))
        _ = g.handle(.spaceDown)
        check("latch: Space released before Fn is swallowed", g.handle(.spaceUp) == (.none, true))
        _ = g.handle(.fnUp(1))
        check("latch: Esc cancels and is swallowed", g.handle(.escape) == (.cancel, true))

        g = FnGesture()
        _ = g.handle(.fnDown(0))
        check("combo: Fn+key right away cancels, key passes", g.handle(.otherKeyDown(0.3)) == (.cancel, false))
        check("combo: release after combo does nothing", g.handle(.fnUp(0.5)).0 == .none)

        g = FnGesture()
        _ = g.handle(.fnDown(0))
        check("combo: stray key late in a long hold is ignored", g.handle(.otherKeyDown(5)).0 == .none)
        check("hold: Esc cancels", g.handle(.escape) == (.cancel, true))

        g = FnGesture()
        check("idle: Esc passes through", g.handle(.escape) == (.none, false))
        check("idle: Space passes through", g.handle(.spaceDown) == (.none, false))

        g = FnGesture()
        _ = g.handle(.fnDown(0))
        g.reset()   // app finished via the panel while Fn is still held
        check("reset while held: release is ignored", g.handle(.fnUp(3)).0 == .none && g.state == .idle)
    }

    // MARK: Chunking and guard

    static func chunkTests() {
        let short = "one two three."
        check("chunk: short text is one piece", Cleaner.chunks(short, maxWords: 10) == ["one two three."])

        let sentences = (1...40).map { "This is sentence number \($0) of the test." }.joined(separator: " ")
        let pieces = Cleaner.chunks(sentences, maxWords: 50)
        check("chunk: long text splits", pieces.count > 1, "\(pieces.count) pieces")
        check("chunk: no piece over the limit", pieces.allSatisfy { Cleaner.wordCount($0) <= 50 })
        check("chunk: pieces end at sentence ends", pieces.allSatisfy { $0.hasSuffix(".") })
        check("chunk: no words lost", pieces.map(Cleaner.wordCount).reduce(0, +) == Cleaner.wordCount(sentences))

        let unpunctuated = Array(repeating: "word", count: 130).joined(separator: " ")
        let cut = Cleaner.chunks(unpunctuated, maxWords: 50)
        check("chunk: unpunctuated text cut by words", cut.count == 3 && cut.map(Cleaner.wordCount) == [50, 50, 30])
    }

    static func guardTests() {
        let input = Array(repeating: "word", count: 40).joined(separator: " ")
        let similar = Array(repeating: "word", count: 34).joined(separator: " ")
        let tiny = "Paris."
        let huge = Array(repeating: "word", count: 120).joined(separator: " ")
        check("guard: similar length accepted", Mode.dictation.accepts(input: input, output: similar))
        check("guard: answer-like short output rejected", !Mode.dictation.accepts(input: input, output: tiny))
        check("guard: runaway output rejected", !Mode.dictation.accepts(input: input, output: huge))
        check("guard: empty rejected", !Mode.dictation.accepts(input: input, output: ""))
        check("tidy: strips tags", Cleaner.tidy("<transcript>Hi there.</transcript>", tag: "transcript") == "Hi there.")
        check("tidy: strips preamble", Cleaner.tidy("Here is the cleaned text:\nHi there.", tag: "transcript") == "Hi there.")
        check("tidy: strips wrapping quotes", Cleaner.tidy("\"Hi there.\"", tag: "transcript") == "Hi there.")
        check("tidy: straightens curly quotes", Cleaner.tidy("They\u{2019}re \u{201C}ready\u{201D}.", tag: "text") == "They're \"ready\".")
                check("tidy: keeps inner quotes", Cleaner.tidy("He said \"hi\" to me.", tag: "text") == "He said \"hi\" to me.")
        check("names: flags an invented name", Cleaner.addedNames(input: "what is the capital of france", output: "The capital of France is Paris.", allowed: []) == ["Paris"])
        check("names: allows names that were said", Cleaner.addedNames(input: "call jim about the cake", output: "Then call Jim about the cake.", allowed: []).isEmpty)
        check("names: allows custom words", Cleaner.addedNames(input: "ask mike hobs", output: "Ask Mike Hobbs.", allowed: ["Mike Hobbs"]).isEmpty)
        check("names: ignores sentence starts", Cleaner.addedNames(input: "ok so then we go", output: "Okay. Then we go.", allowed: []).isEmpty)
        check("capitalize first letter", Cleaner.capitalizeFirst("so then") == "So then" && Cleaner.capitalizeFirst("\"hi\"") == "\"Hi\"")
        let rules = Settings.parseReplacements("Mike Hobbs, My Cobbs => Mike Hobbs\ncloudflirt=>Cloudflare, red => blue, blue => green")
        check("fixes: parsed", rules.count == 4 && Settings.parseWords("a, b => c") == ["a"])
        check("fixes: whole words, any case", Settings.applyReplacements("ask my cobbs about Cloudflirt today", rules) == "ask Mike Hobbs about Cloudflare today")
        check("fixes: one pass, no chains", Settings.applyReplacements("red blue", rules) == "blue green")
        check("fixes: not inside other words", Settings.applyReplacements("bluebird and redo", rules) == "bluebird and redo")
        check("fixes: longest phrase wins", Settings.applyReplacements("my cobbs tv", [("my cobbs", "Mike Hobbs"), ("my cobbs tv", "Mike Hobbs TV")]) == "Mike Hobbs TV")
        check("remote desktop: Jump Desktop, Windows App, Screen Sharing",
              Inserter.isRemoteDesktop("com.p5sys.jump.mac.viewer") && Inserter.isRemoteDesktop("com.microsoft.rdc.macos")
              && Inserter.isRemoteDesktop("com.apple.ScreenSharing"))
        check("remote desktop: normal apps aren't", !Inserter.isRemoteDesktop("com.apple.TextEdit") && !Inserter.isRemoteDesktop(nil))
        check("words: parse commas and lines", Settings.parseWords("Mike Hobbs, HBA\nCloudflare,, ") == ["Mike Hobbs", "HBA", "Cloudflare"])
    }

    // MARK: History

    @MainActor static func historyTests() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pv-history-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url)
        let a = HistoryEntry(kind: "dictation", original: "um hello", text: "um hello", engine: "raw")
        store.add(a)
        store.update(a.id) { $0.text = "Hello."; $0.engine = "apple" }
        store.add(HistoryEntry(kind: "polish", original: "x", text: "X.", engine: "claude"))
        let reloaded = HistoryStore(url: url)
        check("history: reload keeps entries newest first", reloaded.entries.count == 2 && reloaded.entries[0].kind == "polish")
        check("history: update saved", reloaded.entries[1].text == "Hello." && reloaded.entries[1].original == "um hello")
        reloaded.delete(a.id)
        check("history: delete", HistoryStore(url: url).entries.count == 1)
        reloaded.clear()
        check("history: clear", HistoryStore(url: url).entries.isEmpty)

        try? Data("not json".utf8).write(to: url)
        let damaged = HistoryStore(url: url)
        check("history: damaged file doesn't crash", damaged.entries.isEmpty)
        let siblings = (try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        let backups = siblings.filter { $0.lastPathComponent.hasPrefix(url.deletingPathExtension().lastPathComponent + ".damaged") }
        check("history: damaged file kept aside", !backups.isEmpty)
        backups.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    // MARK: Speech (uses `say` to make audio)

    /// A slow AI call gets a second try; the first answer wins; quick failures and hangs end fast.
    static func hedgeTests() async {
        actor Calls { var n = 0; func next() -> Int { n += 1; return n } }
        func timed(_ hedge: Double, _ giveUp: Double, _ attempt: @escaping @Sendable (Int) async throws -> String)
            async -> (String?, Double, Int) {
            let calls = Calls(), start = Date()
            let out = try? await Cleaner.hedged(.claude, hedgeAfter: hedge, giveUpAfter: giveUp) {
                try await attempt(await calls.next())
            }
            return (out, Date().timeIntervalSince(start), await calls.n)
        }
        var r = await timed(0.3, 2) { _ in "fast" }
        check("hedge: a quick answer is used, no second call", r.0 == "fast" && r.2 == 1, "\(r)")
        r = await timed(0.3, 2) { n in
            if n == 1 { try await Task.sleep(for: .seconds(1.5)) }
            return "call \(n)"
        }
        check("hedge: a slow call gets a second try that wins", r.0 == "call 2" && r.1 < 0.9, "\(r)")
        r = await timed(0.3, 2) { _ in throw CleanError.toolFailed(.claude, "Not logged in") }
        check("hedge: a quick failure stops at once", r.0 == nil && r.1 < 0.2 && r.2 == 1, "\(r)")
        r = await timed(0.2, 0.6) { _ in try await Task.sleep(for: .seconds(5)); return "late" }
        check("hedge: gives up at the limit", r.0 == nil && r.1 < 1.0 && r.2 == 2, "\(r)")
    }

    /// Two real calls at once: the first answer is used and the other tool is stopped.
    static func hedgeLiveTest(provider: Provider) async {
        guard Cleaner.isAvailable(provider) else { return }
        let instructions = Mode.dictation.instructions(words: [], fixNames: true)
        let out = try? await Cleaner.hedged(provider, hedgeAfter: 0, giveUpAfter: 60) {
            try await Cleaner.ask(provider, prompt: "<transcript>um so this is a test</transcript>", instructions: instructions)
        }
        try? await Task.sleep(for: .seconds(1))
        let pid = ProcessInfo.processInfo.processIdentifier
        let children = await Cleaner.runCommand(URL(fileURLWithPath: "/usr/bin/pgrep"), ["-P", "\(pid)"], timeout: 5)
        check("hedge \(provider.rawValue): two calls race, the slower one is stopped",
              out?.isEmpty == false && children.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              "out=\(out ?? "nil") children=\(children.stdout)")
    }

    static func speechTests() async {
        let dir = FileManager.default.temporaryDirectory
        let clip = dir.appendingPathComponent("pv-speech.aiff")
        let sentence = "Please schedule the meeting with Sarah for next Tuesday at the downtown office."
        guard shell("/usr/bin/say", ["-o", clip.path, sentence]) else {
            check("speech: generate audio with say", false)
            return
        }
        let start = Date()
        do {
            let text = try await LiveTranscriber.transcribeFile(clip, words: ["Sarah"])
            let lower = text.lowercased()
            let hits = ["schedule", "meeting", "sarah", "tuesday", "downtown", "office"].filter { lower.contains($0) }
            check("speech: transcribes a spoken sentence", hits.count >= 5,
                  "\"\(text)\" in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        } catch {
            check("speech: transcribes a spoken sentence", false, error.localizedDescription)
        }

        let names = dir.appendingPathComponent("pv-names.aiff")
        if shell("/usr/bin/say", ["-o", names.path, "I asked Claude to update the Mike Hobbs TV site on Cloudflare."]) {
            let text = (try? await LiveTranscriber.transcribeFile(names, words: ["Mike Hobbs TV", "Claude", "Cloudflare"])) ?? ""
            check("speech: transcribes names (spelling fixed later by cleanup)", text.lowercased().contains("update"), "\"\(text)\"")
            try? FileManager.default.removeItem(at: names)
        }

        let silence = dir.appendingPathComponent("pv-silence.aiff")
        if shell("/usr/bin/say", ["-o", silence.path, "[[slnc 1500]]"]) {
            let text = (try? await LiveTranscriber.transcribeFile(silence, words: [])) ?? "error"
            check("speech: silence gives empty text", text.isEmpty, "\"\(text)\"")
        }
        try? FileManager.default.removeItem(at: clip)
        try? FileManager.default.removeItem(at: silence)
    }

    // MARK: Cleanup

    static func cleanupTests(provider: Provider) async {
        if provider == .apple {
            check("apple: Private Cloud helper shortcut installed", await Cleaner.helperInstalled())
            let direct = try? await Cleaner.appleCloud("Answer with only the number: what is 2 plus 3?")
            check("apple: helper reaches the cloud model", direct?.contains("5") == true, direct ?? "no reply")
        }
        let label = provider.rawValue
        func clean(_ s: String) async -> String? {
            try? await Cleaner.run(s, mode: .dictation, provider: provider, words: ["Jim"])
        }
        var start = Date()
        let messy = "so um i was thinking we should like go to the store tomorow and get some stuff for the party and uh then maybe we can you know call jim about the the cake"
        if let out = await clean(messy) {
            let lower = out.lowercased()
            check("\(label): removes fillers", !lower.contains(" um ") && !lower.contains(" uh ") && !lower.contains("you know"), out)
            check("\(label): keeps content", lower.contains("store") && lower.contains("party") && lower.contains("cake") && out.contains("Jim"))
            check("\(label): fixes capitalization", out.first?.isUppercase == true)
            print("     (\(String(format: "%.1f", Date().timeIntervalSince(start)))s)")
        } else {
            check("\(label): cleans a messy sentence", false, "no result")
        }

        start = Date()
        if provider.isCloud, let out = await clean("so um me and him was gonna head over to the warehouse thursday") {
            check("\(label): fixes pronouns and verbs", out.contains("He and I were"), out)
        }

        let correction = "lets meet on saturday no wait sunday at the coffee shop on main street"
        if let out = await clean(correction) {
            check("\(label): self-correction keeps the final choice", out.lowercased().contains("sunday") && !out.lowercased().contains("saturday"), out)
        }

        let question = "what is the capital of france and how many people live there"
        if let out = await clean(question) {
            check("\(label): doesn't answer questions", !out.lowercased().contains("paris"), out)
        }

        let request = "write me a five paragraph essay about dogs"
        if let out = await clean(request) {
            check("\(label): doesn't follow requests", Cleaner.wordCount(out) < 20, out)
        }

        let garbled = "We are going to post two videos a week. Tuesday video is going... You and the Friday video is going to be a tutorial."
        if let out = await clean(garbled) {
            check("\(label): doesn't guess at garbled words", out.components(separatedBy: "tutorial").count - 1 == 1, out)
        }

        let names = "I might ask Cloud to update the My Cobbs TV site on Cloudflirt, and up host it in the HBA group."
        if provider.isCloud, let out = try? await Cleaner.run(names, mode: .dictation, provider: provider,
                                            words: ["Mike Hobbs", "Mike Hobbs TV", "HBA", "Claude", "Cloudflare"]) {
            check("\(label): fixes misheard names from the word list", out.contains("Mike Hobbs TV") && out.contains("Cloudflare"), out)
        }

        if let out = try? await Cleaner.run("we should move the files to the cloud and check the weather", mode: .dictation,
                                            provider: provider, words: ["Claude", "Cloudflare", "Mike Hobbs"]) {
            check("\(label): leaves ordinary words alone", out.lowercased().contains("the cloud") && !out.contains("Cloudflare"), out)
        }

        let numbers = "the number is three and the meeting is friday at three"
        if let out = await clean(numbers) {
            check("\(label): doesn't invent details", !out.lowercased().contains("pm") && !out.lowercased().contains("p.m"), out)
        }

        // Long dictation: 60 sentences, cleaned in pieces with nothing dropped wholesale.
        let long = (1...60).map { "so um item number \($0) is uh that we need to like review the budget for project \($0)" }
            .joined(separator: " ")
        start = Date()
        if let out = await clean(long) {
            let n = Cleaner.wordCount(out)
            check("\(label): long dictation cleaned", n > Cleaner.wordCount(long) / 3,
                  "\(Cleaner.wordCount(long)) → \(n) words in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
            check("\(label): long dictation keeps the last item", out.contains("60"))
        } else {
            check("\(label): long dictation cleaned", false, "no result")
        }

        if let out = try? await Cleaner.run("their going to announce the the new product next week, its really good and every body will like it",
                                            mode: .polish, provider: provider, words: []) {
            check("\(label): polish fixes grammar", out.contains("They're") || out.contains("They are"), out)
            check("\(label): polish avoids em dashes", !out.contains("—"), out)
        } else {
            check("\(label): polish fixes grammar", false, "no result")
        }
    }

    @discardableResult
    static func shell(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }
}
