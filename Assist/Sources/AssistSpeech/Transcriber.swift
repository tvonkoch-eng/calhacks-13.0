import AVFoundation
import Foundation
import Speech

/// Where audio comes from. A file is played through the recognizer in real time by default, so
/// timings match a live mic and a recorded failure can be replayed exactly.
public enum AudioInput: Sendable {
    case microphone
    case file(URL, realTime: Bool = true)
}

public enum TranscriberError: LocalizedError {
    case unavailable, noFormat, micDenied

    public var errorDescription: String? {
        switch self {
        case .unavailable: "On-device speech transcription is not available on this device"
        case .noFormat: "No audio format the transcriber accepts"
        case .micDenied: "Microphone access denied (System Settings › Privacy & Security › Microphone)"
        }
    }
}

/// Live, on-device speech-to-text with Apple's SpeechAnalyzer (macOS 26 / iOS 26).
///
/// Chosen over SFSpeechRecognizer because it streams word-by-word "volatile" hypotheses, closes
/// each sentence itself (with punctuation, including "?"), and handles long-form audio with no
/// one-minute cap, so there is no per-utterance session rotation to get wrong. The old rotation
/// was the source of questions being cut in half: the previous session's late "final" callback
/// would land during the next sentence and flush it early.
@MainActor public final class Transcriber {
    /// Words to favour in recognition. Add event, venue and people names here.
    public static var vocabulary = [
        "Cal Hacks", "CalHacks", "Berkeley", "UC Berkeley", "Groq", "Joaquin", "Toby", "Avi",
        "Mirabelle", "Presidio", "Palace of Fine Arts", "Meta Ray-Ban", "Moss", "hackathon",
    ]

    /// (text of the sentence in progress, recognizer closed the sentence, audio time it ends at)
    public typealias Handler = @MainActor (_ text: String, _ final: Bool, _ audioEnd: Double?) -> Void

    public var locale = Locale(identifier: "en-US")
    /// Which Apple recognizer to run. `.speech` is the new conversational model; `.dictation` is
    /// the older one, which supports a far-field hint (speaker away from the mic).
    public enum Model: String, Sendable { case speech, dictation, dictationFar }
    public var model: Model = .speech
    public var useVocabulary = true
    /// Audio-clock start of the result being delivered to the handler right now (read it inside
    /// the handler). Lets a second pass cut out exactly the audio of a finished sentence.
    public private(set) var resultStart: Double?
    /// Every buffer fed to the recognizer, in the recognizer's format, with its start time on
    /// the audio clock. For keeping recent audio around (second-opinion transcription).
    public var onAudio: (@Sendable (AVAudioPCMBuffer, Double) -> Void)?
    public var status: (@MainActor (String) -> Void)?
    /// Microphone level 0...1, for a meter.
    public var level: (@Sendable (Float) -> Void)?

    public init() {}

    /// Runs until the input ends (file) or the task is cancelled (mic).
    /// `onStart` fires the instant the first audio is about to be fed: zero on the audio clock.
    public func run(_ input: AudioInput, onStart: @MainActor () -> Void, handler: @escaping Handler) async throws {
        guard SpeechTranscriber.isAvailable else { throw TranscriberError.unavailable }
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: self.locale) ?? self.locale
        let speech: SpeechTranscriber?
        let dictation: DictationTranscriber?
        let module: any SpeechModule
        switch model {
        case .speech:
            let t = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: ProcessInfo.processInfo.environment["ASSIST_NO_FAST"] == nil
                    ? [.volatileResults, .fastResults] : [.volatileResults],
                attributeOptions: [.audioTimeRange]
            )
            speech = t; dictation = nil; module = t
        case .dictation, .dictationFar:
            let t = DictationTranscriber(
                locale: locale,
                contentHints: model == .dictationFar ? [.farField] : [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization],
                attributeOptions: [.audioTimeRange]
            )
            speech = nil; dictation = t; module = t
        }
        if let download = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            status?("Preparing speech model…")
            try await download.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriberError.noFormat
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        // Names the recognizer otherwise mangles ("Cal Hacks" came out as "Cowhags", "California
        // hat", "Calhax"). Biases recognition toward them; harmless if they never come up.
        if useVocabulary {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Self.vocabulary
            try? await analyzer.setContext(context)
        }
        let (inputs, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: inputs)

        let reader = Task { @MainActor in
            if let speech {
                for try await result in speech.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    let end = result.range.end
                    self.resultStart = result.range.start.isNumeric ? result.range.start.seconds : nil
                    handler(text, result.isFinal, end.isNumeric ? end.seconds : nil)
                }
            } else if let dictation {
                for try await result in dictation.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    let end = result.range.end
                    self.resultStart = result.range.start.isNumeric ? result.range.start.seconds : nil
                    handler(text, result.isFinal, end.isNumeric ? end.seconds : nil)
                }
            }
        }

        status?("Listening")
        do {
            try await pump(input, into: feed, format: format, onStart: onStart)
        } catch is CancellationError {
        }
        feed.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await reader.value
    }

    private func pump(_ input: AudioInput, into feed: AsyncStream<AnalyzerInput>.Continuation,
                      format: AVAudioFormat, onStart: @MainActor () -> Void) async throws {
        let converter = Converter(to: format)
        let tap = onAudio
        let clock = FedClock()
        // Every buffer the recognizer sees, also handed to `onAudio` with its time on the audio clock.
        func send(_ buffer: AVAudioPCMBuffer) {
            let t = clock.advance(Double(buffer.frameLength) / buffer.format.sampleRate)
            tap?(buffer, t)
            feed.yield(AnalyzerInput(buffer: buffer))
        }
        switch input {
        case .file(let url, let realTime):
            let file = try AVAudioFile(forReading: url)
            let rate = file.processingFormat.sampleRate
            let chunk = AVAudioFrameCount(rate * 0.05)
            onStart()
            let start = Date()
            var sent = 0.0
            func pace() async throws {
                guard realTime else { return }
                let ahead = sent - Date().timeIntervalSince(start)
                if ahead > 0 { try await Task.sleep(for: .seconds(ahead)) }
            }
            while file.framePosition < file.length {
                try Task.checkCancellation()
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
                try file.read(into: buffer, frameCount: chunk)
                if buffer.frameLength == 0 { break }
                send(try converter.convert(buffer))
                sent += Double(buffer.frameLength) / rate
                try await pace()
            }
            // Room tone after the last word, like a live mic, so the recognizer closes the sentence
            // on its own timing rather than because the input ended.
            for _ in 0..<40 {
                try Task.checkCancellation()
                send(Converter.silence(format, seconds: 0.05))
                sent += 0.05
                try await pace()
            }

        case .microphone:
            guard await AVAudioApplication.requestRecordPermission() else { throw TranscriberError.micDenied }
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            // .mixWithOthers so the glasses' own audio session never takes the mic away.
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            // The input device can change under us (AirPods switching to their mic profile a second
            // or two after the mic opens, a headset plugged in, another app changing the sample
            // rate). AVAudioEngine then stops silently and the tap never fires again. So: watch for
            // configuration changes and for audio simply ceasing, and rebuild the engine.
            let level = self.level
            var started = false
            while true {
                try Task.checkCancellation()
                let engine = AVAudioEngine()
                let node = engine.inputNode
                let format = node.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    status?("No microphone input available; retrying")
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
                let pulse = Pulse()
                node.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                    pulse.beat()
                    level?(Converter.level(buffer))
                    if let converted = try? converter.convert(buffer) { send(converted) }
                }
                let changed = Pulse()
                let observer = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in changed.beat() }
                defer {
                    NotificationCenter.default.removeObserver(observer)
                    node.removeTap(onBus: 0)
                    engine.stop()
                }
                engine.prepare()
                try engine.start()
                if !started { onStart(); started = true }
                status?("Listening (mic \(Int(format.sampleRate)) Hz, \(format.channelCount) ch)")
                var reason = ""
                while reason.isEmpty {
                    try await Task.sleep(for: .milliseconds(250))
                    if changed.count > 0 { reason = "audio device changed" }
                    else if pulse.age > 1.5 { reason = "mic stopped delivering audio" }
                    else if !engine.isRunning { reason = "audio engine stopped" }
                }
                status?("\(reason); restarting the mic")
            }
        }
    }
}

/// Seconds of audio fed so far (the recognizer's clock). Audio-thread safe.
final class FedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = 0.0
    /// Returns the start time of the span just added.
    func advance(_ seconds: Double) -> Double { lock.lock(); defer { lock.unlock() }; let s = t; t += seconds; return s }
}

/// Thread-safe "last time something happened" for the realtime audio thread.
final class Pulse: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    private var n = 0
    func beat() { lock.lock(); last = Date(); n += 1; lock.unlock() }
    var age: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Converts whatever the source produces to the format the transcriber wants.
final class Converter: @unchecked Sendable {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private let lock = NSLock()

    init(to target: AVAudioFormat) { self.target = target }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format == target { return buffer }
        lock.lock()
        defer { lock.unlock() }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.primeMethod = .none
        }
        guard let converter else { throw TranscriberError.noFormat }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw TranscriberError.noFormat }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if given {
                inputStatus.pointee = .noDataNow
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error, let error { throw error }
        return out
    }

    static func silence(_ format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for b in list { if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) } }
        return buffer
    }

    static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let db = 10 * log10(max(sum / Float(buffer.frameLength), 1e-12))
        return max(0, min(1, (db + 60) / 60))
    }
}
