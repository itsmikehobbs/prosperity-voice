import AppKit
import AVFoundation

/// Runs one dictation at a time: record → transcribe → clean → save → paste.
@MainActor
final class Controller: ObservableObject {
    enum Phase: Equatable { case idle, recording, processing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastError: String?

    let history: HistoryStore
    let panel = RecordingPanel()
    let hotkey = Hotkey()
    /// A fresh recorder per session, so a slow finish can never collide with the next recording.
    private var transcriber = LiveTranscriber()
    /// Changes whenever a session ends, so stale async results can never paste.
    private var session = UUID()
    private var startedAt = Date()
    private var targetApp: String?
    /// Long dictations are cleaned in pieces while you're still talking, so letting go
    /// only leaves the last few sentences to clean.
    private var earlyCleanups: [Task<CleanResult, Never>] = []
    private var uncleanedText = ""
    private var liveEngine: CleanupEngine = .apple

    init(history: HistoryStore) {
        self.history = history
        panel.model.onFinish = { [weak self] in self?.finish() }
        panel.model.onCancel = { [weak self] in self?.cancel() }
        hotkey.onAction = { [weak self] action in self?.handle(action) }
    }

    func handle(_ action: GestureAction) {
        switch action {
        case .start: start()
        case .latch: if phase == .recording { panel.model.handsFree = true }
        case .finish: finish()
        case .cancel: cancel(quiet: true)
        case .none: break
        }
    }

    /// Start/stop from the menu (toggle).
    func toggle() {
        switch phase {
        case .idle: start(handsFree: true)
        case .recording: finish()
        case .processing: break
        }
    }

    func start(handsFree: Bool = false) {
        guard phase == .idle else {
            if phase == .processing { hotkey.resetGesture() }
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            hotkey.resetGesture()
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            panel.flash("Allow the microphone, then try again", good: false, seconds: 3)
            return
        default:
            hotkey.resetGesture()
            panel.flash("Microphone is blocked. Open Settings in the menu.", good: false, seconds: 3)
            return
        }
        session = UUID()
        startedAt = Date()
        targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
        Inserter.prime()
        resetEarlyCleanup()
        liveEngine = Settings.cleanupEngine
        let token = session
        transcriber = LiveTranscriber()
        transcriber.onLevel = { [weak self] level in
            if self?.session == token { self?.panel.model.push(level: level) }
        }
        transcriber.onSegment = { [weak self] piece in
            if self?.session == token { self?.receive(segment: piece) }
        }
        let watchdog = MicWatchdog.arm("start")
        do {
            try transcriber.start(recordingTo: Paths.currentRecording, words: Settings.customWords)
            MicWatchdog.disarm(watchdog)
        } catch {
            MicWatchdog.disarm(watchdog)
            hotkey.resetGesture()
            fail("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }
        phase = .recording
        Log.write("start app=\(targetApp ?? "-") engine=\(liveEngine.rawValue)")
        panel.showRecording(handsFree: handsFree)
        sound("Tink")
        if Settings.muteWhileRecording {
            // After the start sound has played. Skipped if the recording already ended.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.phase == .recording, self.session == token else { return }
                AudioMuter.mute()
            }
        }
    }

    func finish() {
        guard phase == .recording else { return }
        hotkey.resetGesture()
        phase = .processing
        AudioMuter.restore()
        sound("Pop")
        panel.showWorking("Transcribing…")
        let token = session
        let seconds = Date().timeIntervalSince(startedAt)
        let recorder = transcriber
        Task {
            do {
                let raw = try await recorder.stop()
                keepRecording()
                guard token == session else { return }
                await deliver(raw: raw, seconds: seconds, token: token)
            } catch {
                keepRecording()
                Log.write("transcription error: \(error)")
                guard token == session else { return }
                fail("Transcription failed. Use Retry last recording in the menu.")
            }
        }
    }

    func cancel(quiet: Bool = false) {
        switch phase {
        case .recording:
            Log.write("cancel while recording")
            AudioMuter.restore()
            transcriber.cancel()
            resetEarlyCleanup()
            keepRecording()
            session = UUID()
            phase = .idle
            hotkey.resetGesture()
            // A quick accidental Fn tap just disappears; a real cancel says so.
            if quiet && Date().timeIntervalSince(startedAt) < 1.0 { panel.hide() } else { panel.flash("Cancelled", good: false, seconds: 1) }
        case .processing:
            session = UUID()
            resetEarlyCleanup()
            phase = .idle
            panel.flash("Cancelled (saved in history if transcribed)", good: false, seconds: 1.5)
        case .idle:
            break
        }
    }

    /// Re-transcribe the last recording (after a failure, cancel, or just to redo it).
    func retryLast() {
        guard phase == .idle, FileManager.default.fileExists(atPath: Paths.lastRecording.path) else {
            panel.flash("No saved recording to retry", good: false)
            return
        }
        phase = .processing
        session = UUID()
        let token = session
        panel.showWorking("Transcribing last recording…")
        Task {
            do {
                let raw = try await LiveTranscriber.transcribeFile(Paths.lastRecording, words: Settings.customWords)
                guard token == session else { return }
                await deliver(raw: raw, seconds: nil, token: token)
            } catch {
                guard token == session else { return }
                fail("Retry failed: \(error.localizedDescription)")
            }
        }
    }

    private func deliver(raw: String, seconds: Double?, token: UUID) async {
        guard !raw.isEmpty else {
            fail("Didn't catch any words. Recording kept for Retry.")
            return
        }
        // Save what was heard before anything else can go wrong.
        var entry = HistoryEntry(kind: "dictation", original: raw, text: raw, engine: "raw", app: targetApp, seconds: seconds)
        let keep = Settings.keepHistory
        if keep { history.add(entry) }

        // Take this session's early pieces now; all segments have arrived once the transcript is final.
        let early = earlyCleanups
        let tail = uncleanedText
        earlyCleanups = []
        uncleanedText = ""
        let engine = early.isEmpty ? Settings.cleanupEngine : liveEngine
        if let provider = engine.provider {
            panel.showWorking(provider.isCloud ? "Cleaning up with \(provider.name)…" : "Cleaning up…")
        }
        let result: CleanResult
        if early.isEmpty {
            let fixed = Settings.applyReplacements(raw, Settings.replacements)
            result = await Cleaner.cleanDictation(fixed, engine: engine, words: Settings.customWords)
        } else {
            result = await combine(early: early, tail: tail, engine: engine)
        }
        guard token == session else { return }

        let focus = Inserter.describeFocus()
        let outcome = await Inserter.insert(result.text)
        Log.write("deliver words=\(Cleaner.wordCount(raw))→\(Cleaner.wordCount(result.text)) engine=\(result.engine) early=\(early.count) note=\(result.note ?? "-") outcome=\(outcome) focus=[\(focus)]")
        entry.text = result.text
        entry.engine = result.engine
        entry.pasted = outcome == .pasted
        if keep { history.update(entry.id) { $0 = entry } }

        phase = .idle
        lastError = nil
        let base = outcome == .pasted ? "Pasted" : "Copied. Press ⌘V to paste."
        panel.flash(result.note.map { "\(base) (\($0))" } ?? base, good: true, seconds: outcome == .pasted ? 1.2 : 2.5)
    }

    // MARK: Cleaning while recording

    private func receive(segment: String) {
        guard phase != .idle, liveEngine != .off else { return }
        uncleanedText += (uncleanedText.isEmpty ? "" : " ") + segment
        let threshold = liveEngine.provider?.isCloud == true ? 1200 : Cleaner.appleChunkWords
        guard Cleaner.wordCount(uncleanedText) >= threshold,
              let last = uncleanedText.last, ".!?".contains(last) else { return }
        let piece = Settings.applyReplacements(uncleanedText, Settings.replacements)
        uncleanedText = ""
        let engine = liveEngine, words = Settings.customWords
        earlyCleanups.append(Task.detached(priority: .userInitiated) {
            await Cleaner.cleanDictation(piece, engine: engine, words: words)
        })
    }

    private func combine(early: [Task<CleanResult, Never>], tail: String, engine: CleanupEngine) async -> CleanResult {
        var parts: [CleanResult] = []
        for task in early { parts.append(await task.value) }
        if !tail.isEmpty {
            let tail = Settings.applyReplacements(tail, Settings.replacements)
            parts.append(await Cleaner.cleanDictation(tail, engine: engine,
                                                      words: Settings.customWords))
        }
        let engines = Set(parts.map(\.engine))
        return CleanResult(text: parts.map(\.text).joined(separator: " "),
                           engine: engines.count == 1 ? engines.first! : "mixed",
                           note: parts.compactMap(\.note).first)
    }

    private func resetEarlyCleanup() {
        earlyCleanups.forEach { $0.cancel() }
        earlyCleanups = []
        uncleanedText = ""
    }

    private func fail(_ message: String) {
        Log.write("fail: \(message)")
        phase = .idle
        lastError = message
        panel.flash(message, good: false, seconds: 3.5)
    }

    /// Move the just-finished recording to last.wav so Retry can use it.
    private func keepRecording() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.currentRecording.path) else { return }
        try? fm.removeItem(at: Paths.lastRecording)
        try? fm.moveItem(at: Paths.currentRecording, to: Paths.lastRecording)
    }

    private func sound(_ name: String) {
        guard Settings.playSounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    // MARK: Polish (right-click service)

    /// Polish selected text. Returns nil to leave the selection unchanged.
    func polish(_ text: String) async -> String? {
        let provider = Settings.polishEngine.provider
        panel.showWorking(provider.isCloud ? "Polishing with \(provider.name)…" : "Polishing…")
        do {
            let result = try await Cleaner.polish(text, engine: Settings.polishEngine,
                                                  words: Settings.customWords)
            if Settings.keepHistory {
                history.add(HistoryEntry(kind: "polish", original: text, text: result.text, engine: result.engine,
                                         app: NSWorkspace.shared.frontmostApplication?.localizedName, pasted: true))
            }
            panel.flash("Polished")
            return result.text
        } catch {
            panel.flash("Polish failed: \(error.localizedDescription)", good: false, seconds: 3)
            return nil
        }
    }
}
