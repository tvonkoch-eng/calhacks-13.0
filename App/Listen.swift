import AVFoundation
import Foundation
import Observation
import Speech

/// Continuous phone-mic listening tuned for latency, not transcript beauty.
///
/// Three things make it fast:
/// 1. On-device recognition, so partial hypotheses arrive in ~100-200 ms with no network hop.
/// 2. Our own endpointing. Apple's recognizer only finalizes after ~1.5 s of silence; we call a
///    sentence over after `endpointSilence` of quiet, which is the biggest single win available.
/// 3. One recognizer request per utterance, so hypotheses stay short and a long conversation never
///    runs into the recognizer's ~1 minute cap.
@MainActor @Observable final class Listener {
    var transcript = ""
    var listening = false
    var level: Float = 0
    var status = "Idle"

    /// Every new hypothesis for the current utterance. `endpointed` means speech just stopped.
    @ObservationIgnored var onUpdate: ((_ text: String, _ endpointed: Bool) -> Void)?

    /// Quiet — no voice *and* no transcript growth — that ends an utterance.
    private let endpointSilence: TimeInterval = 0.32

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @ObservationIgnored private let sink = Sink()
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    /// Last moment we had evidence someone was still talking.
    @ObservationIgnored private var clock = Date()
    @ObservationIgnored private var noiseFloor: Float = -50
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    func start() async {
        guard !listening else { return }
        guard await Self.authorize() else {
            status = "Mic or speech permission denied"
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            status = "Speech recognition unavailable"
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            // .mixWithOthers so the glasses' own audio session never takes the mic away from us.
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            // Realtime audio thread: feed the recognizer directly (its append is thread-safe) and
            // send only a level reading to the main actor. The buffer itself must not outlive this.
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, sink = self.sink] buffer, _ in
                sink.append(buffer)
                let db = Sink.decibels(buffer)
                Task { @MainActor in self?.measured(db) }
            }
            engine.prepare()
            try engine.start()

            listening = true
            status = "Listening"
            rotate()
            watch()
        } catch {
            status = "Mic failed: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        sink.finish()
        task?.cancel()
        task = nil
        transcript = ""
        level = 0
        listening = false
        status = "Idle"
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Voice activity

    private func measured(_ db: Float) {
        level = max(0, min(1, (db + 60) / 60))
        let voiced = db > noiseFloor + 8
        if voiced {
            clock = Date()
        } else {
            // The floor only drifts while we believe the room is quiet, clamped to plausible noise.
            noiseFloor = min(-25, max(-60, noiseFloor * 0.98 + db * 0.02))
        }
    }

    // MARK: - Recognition

    /// Fresh recognizer request for the next utterance.
    private func rotate() {
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer?.supportsOnDeviceRecognition ?? false
        request.addsPunctuation = true
        request.taskHint = .dictation
        sink.use(request)
        transcript = ""
        clock = Date()
        // The handler fires on an arbitrary queue; pull out plain values before hopping over.
        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let closed = result?.isFinal == true || error != nil
            Task { @MainActor in self?.received(text, closed: closed) }
        }
    }

    private func received(_ text: String?, closed: Bool) {
        if let text, !text.isEmpty, text != transcript {
            transcript = text
            clock = Date()
            onUpdate?(text, false)
        }
        // Apple decided the utterance was over before we did: flush and start the next one.
        if closed, listening { flush() }
    }

    /// 60 ms tick — the only thing that decides an utterance has ended.
    private func watch() {
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, self.listening else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard !transcript.isEmpty, Date().timeIntervalSince(clock) > endpointSilence else { return }
        flush()
    }

    private func flush() {
        let text = transcript
        transcript = ""
        guard !text.isEmpty else { return }
        onUpdate?(text, true)
        rotate()
    }

    // MARK: - Permissions

    private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// Hands audio from the realtime tap to whichever recognizer request is current. The tap cannot
/// touch main-actor state, and the request it should feed changes once per utterance, so the
/// pointer lives behind an uncontended lock rather than crossing an actor boundary per buffer.
private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func use(_ next: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        let previous = request
        request = next
        lock.unlock()
        previous?.endAudio()
    }

    func finish() { use(nil) }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
    }

    static func decibels(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return -120 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return -120 }
        var sum: Float = 0
        for i in 0..<frames { sum += data[i] * data[i] }
        return 10 * log10(max(sum / Float(frames), 1e-12))
    }
}
