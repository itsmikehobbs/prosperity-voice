import AVFoundation
import Speech

enum TranscribeError: LocalizedError {
    case notRunning
    case noInput
    var errorDescription: String? {
        switch self {
        case .notRunning: return "Recording wasn't running."
        case .noInput: return "No microphone input was found."
        }
    }
}

/// Records from the default microphone and transcribes live with Apple's on-device
/// SpeechAnalyzer while you talk. Audio is also written to a WAV file for retry.
/// No time limit: text is finalized as you go, so stopping only finishes the tail.
final class LiveTranscriber {
    static let locale = Locale(identifier: "en-US")

    /// Called on the main thread with a 0...1 input level.
    var onLevel: ((Float) -> Void)?
    /// Called on the main actor, in order, with each finalized piece of transcript.
    var onSegment: (@MainActor (String) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    // Guarded by `lock` (touched from the audio thread).
    private var converter: AnalyzerInputConverter?
    private var pending: [(AVAudioPCMBuffer, AVAudioTime)] = []
    private var file: AVAudioFile?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var accepting = false

    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<String, Error>?
    private var setupTask: Task<Void, Error>?
    private var configObserver: NSObjectProtocol?
    private var lastLevelPost = 0.0
    /// Loudest moment of the recording (dBFS). Silence makes the dictation model hallucinate
    /// short words like "No", so a recording that never got loud is treated as no speech.
    private var peakDb: Float = -160
    static let speechThresholdDb: Float = -50

    /// Apple's general on-device speech model. Tested against DictationTranscriber: the dictation model
    /// spells custom words better but drops whole phrases on quieter audio, which cleanup can't recover.
    /// Name spelling is fixed in the cleanup step instead (it gets the custom word list).
    static func makeModule() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    }

    /// Reserve the locale and download the speech model if needed. Safe to call repeatedly.
    static func prepareModel() async throws {
        _ = try? await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeModule()]) {
            try await request.downloadAndInstall()
        }
    }

    static func context(words: [String]) -> AnalysisContext {
        let context = AnalysisContext()
        if !words.isEmpty { context.contextualStrings[.general] = words }
        return context
    }

    // MARK: Live

    /// Starts the microphone immediately (so no words are lost), then brings the
    /// analyzer up in the background and feeds it everything captured so far.
    func start(recordingTo url: URL, words: [String]) throws {
        try? FileManager.default.removeItem(at: url)
        lock.lock(); accepting = true; pending = []; converter = nil; file = nil; lock.unlock()
        peakDb = -160

        try installTapAndStart()
        observeConfigChanges()

        let module = Self.makeModule()
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [module],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        self.analyzer = analyzer
        let onSegment = self.onSegment
        resultsTask = Task { try await Self.collect(module, onSegment: onSegment) }

        setupTask = Task { [weak self] in
            try await Self.prepareModel()
            let conv = try await AnalyzerInputConverter.converter(compatibleWith: [module])
            try await analyzer.setContext(Self.context(words: words))
            try await analyzer.start(inputSequence: stream)
            guard let self else { cont.finish(); return }
            self.lock.withLock {
                guard self.accepting else { cont.finish(); return }   // cancelled while starting up
                self.continuation = cont
                self.converter = conv
                let backlog = self.pending
                self.pending = []
                for (buffer, time) in backlog { self.feed(buffer, at: time) }
            }
        }
    }

    /// Stops recording and returns the full transcript.
    func stop() async throws -> String {
        teardownAudio()
        guard let setupTask, let analyzer, let resultsTask else { throw TranscribeError.notRunning }
        do {
            try await setupTask.value   // surfaces model/setup errors
        } catch {
            cancel()
            throw error
        }
        lock.withLock {
            accepting = false
            if let rest = try? converter?.flush() { for input in rest { write(input) } }
            continuation?.finish()
            continuation = nil
            file = nil              // closes the WAV
        }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await resultsTask.value
        clear()
        Log.write(String(format: "recording peak %.0f dBFS", peakDb))
        return peakDb < Self.speechThresholdDb ? "" : text
    }

    /// Stops without transcribing. The audio captured so far stays on disk.
    func cancel() {
        teardownAudio()
        lock.lock()
        accepting = false
        continuation?.finish()
        continuation = nil
        file = nil
        lock.unlock()
        setupTask?.cancel()
        resultsTask?.cancel()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        clear()
    }

    private func clear() {
        analyzer = nil
        resultsTask = nil
        setupTask = nil
    }

    // MARK: Audio

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw TranscribeError.noInput }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            self?.receive(buffer, at: time)
        }
        engine.prepare()
        try engine.start()
    }

    private func teardownAudio() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Mic switched (AirPods connected, etc.): reinstall the tap on the new format.
    private func observeConfigChanges() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); let live = self.accepting; self.lock.unlock()
            guard live else { return }
            let watchdog = MicWatchdog.arm("switch")
            try? self.installTapAndStart()
            MicWatchdog.disarm(watchdog)
        }
    }

    private func receive(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        postLevel(buffer)
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return }
        if converter == nil {
            if let copy = buffer.copy() as? AVAudioPCMBuffer { pending.append((copy, time)) }
        } else {
            feed(buffer, at: time)
        }
    }

    /// Caller holds `lock`.
    private func feed(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let converter, let inputs = try? converter.convert(buffer, at: nil) else { return }
        for input in inputs { write(input) }
    }

    /// Caller holds `lock`.
    private func write(_ input: AnalyzerInput) {
        continuation?.yield(input)
        let pcm = input.buffer
        if file == nil {
            file = try? AVAudioFile(forWriting: Paths.currentRecording, settings: pcm.format.settings,
                                    commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
        }
        try? file?.write(from: pcm)
    }

    static func rmsDb(_ buffer: AVAudioPCMBuffer) -> Float? {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        var sum: Float = 0
        let n = Int(buffer.frameLength)
        for i in 0..<n { sum += data[i] * data[i] }
        return 20 * log10(max((sum / Float(n)).squareRoot(), 0.000_01))
    }

    private func postLevel(_ buffer: AVAudioPCMBuffer) {
        guard let db = Self.rmsDb(buffer) else { return }
        peakDb = max(peakDb, db)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLevelPost > 0.05 else { return }
        lastLevelPost = now
        let level = max(0, min(1, (db + 55) / 45))
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    // MARK: Files

    private static func collect(_ module: SpeechTranscriber,
                                onSegment: (@MainActor (String) -> Void)? = nil) async throws -> String {
        var parts: [String] = []
        for try await result in module.results where result.isFinal {
            let text = String(result.text.characters)
            parts.append(text)
            if let onSegment {
                let piece = normalize(text)
                if !piece.isEmpty { await onSegment(piece) }
            }
        }
        return normalize(parts.joined(separator: " "))
    }

    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Transcribe a saved audio file (used for "Retry last recording" and self-tests).
    static func transcribeFile(_ url: URL, words: [String]) async throws -> String {
        try await prepareModel()
        let module = makeModule()
        let converter = try await AnalyzerInputConverter.converter(compatibleWith: [module])
        let audio = try AVAudioFile(forReading: url)
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [module],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        try await analyzer.setContext(context(words: words))
        let results = Task { try await collect(module) }
        try await analyzer.start(inputSequence: stream)

        let chunk: AVAudioFrameCount = 16_384
        var peak: Float = -160
        while audio.framePosition < audio.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: chunk) else { break }
            try audio.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            peak = max(peak, rmsDb(buffer) ?? -160)
            for input in try converter.convert(buffer, at: nil) { cont.yield(input) }
        }
        for input in try converter.flush() { cont.yield(input) }
        cont.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await results.value
        return peak < speechThresholdDb ? "" : text
    }
}
