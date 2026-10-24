import AVFoundation
import Foundation
import Observation

/// Continuous listening, transcribed by Meta's Muse Voice Transcribe over its realtime websocket
/// (wss://api.meta.ai/v1/asr/realtime), in DIARIZATION mode: every finished turn comes with a
/// speaker label ("A", "B"), and a turn runs until the speaker changes.
///
/// The server does the hard parts: cumulative partials ~100-300 ms behind the audio, turn
/// boundaries, and who spoke. We add one thing it can't know: how loud each turn was at our mic,
/// which is how the aid tells the wearer (closest to the mic) from the other person. One socket
/// stays open for the whole conversation; if the server ends it we open another.
///
/// Runs on iOS (phone mic) and macOS (tools/live-mac.swift), from the mic or, for testing, from an
/// audio file streamed at real time and never played aloud.
@MainActor @Observable final class Listener {
    var transcript = ""
    var listening = false
    var level: Float = 0
    var status = "Idle"

    /// The turn in progress, cumulative.
    @ObservationIgnored var onPartial: ((String) -> Void)?
    /// A finished turn: its text, Muse's speaker label, and its loudness at our mic in dB.
    @ObservationIgnored var onLine: ((_ text: String, _ speaker: String?, _ level: Float?) -> Void)?
    /// Words to bias recognition toward, e.g. the names of the people in the room.
    @ObservationIgnored var keywords: [String] = []
    /// Stream this file instead of the mic (testing). Called back with `onFileEnd` when it ran out.
    @ObservationIgnored var file: URL?
    @ObservationIgnored var onFileEnd: (() -> Void)?

    static let model = "muse-voice-transcribe-1.0"
    static let mode = "DIARIZATION"
    static let endpoint = URL(string: "wss://api.meta.ai/v1/asr/realtime")!

    /// Set `MUSE_API_KEY` in Secrets.xcconfig (see Secrets.example.xcconfig).
    static var key: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "MuseAPIKey") as? String
        return (value?.isEmpty == false) ? value : nil
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let uplink = Uplink()
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var player: Task<Void, Never>?
    /// Bumped per socket so events from a dead one are ignored.
    @ObservationIgnored private var connection = 0
    /// Muse's labels are per session; after a reconnect "A" may be someone else, so later sessions'
    /// labels get the session number ("A2") and who's-who is learned again.
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var speaker: String?
    @ObservationIgnored private var turnStart = 0

    func start() async {
        guard !listening else { return }
        guard Self.key != nil else {
            status = "No Muse API key — add MUSE_API_KEY to Secrets.xcconfig"
            return
        }
        do {
            if let file {
                let audio = try AVAudioFile(forReading: file)
                try uplink.prepare(from: audio.processingFormat)
                listening = true
                connect()
                play(audio)
                return
            }
            guard await AVAudioApplication.requestRecordPermission() else {
                status = "Mic permission denied"
                return
            }
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            // .mixWithOthers so the glasses' own audio session never takes the mic away from us.
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            try uplink.prepare(from: format)
            input.removeTap(onBus: 0)
            // Realtime audio thread: hand the buffer to the uplink (it converts and sends off this
            // thread) and send only a level reading to the main actor.
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, uplink = self.uplink] buffer, _ in
                uplink.push(buffer)
                let db = Uplink.decibels(buffer)
                Task { @MainActor in self?.level = max(0, min(1, (db + 60) / 60)) }
            }
            engine.prepare()
            try engine.start()

            listening = true
            connect()
        } catch {
            status = "Audio failed: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        connection += 1
        player?.cancel()
        player = nil
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        uplink.use(nil)
        reader?.cancel()
        reader = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        transcript = ""
        level = 0
        listening = false
        status = "Idle"
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// A file, paced at real time once the socket is ready, then 3 s of silence so the last turn
    /// completes.
    private func play(_ audio: AVAudioFile) {
        let format = audio.processingFormat
        player = Task { [weak self, uplink] in
            while !uplink.ready, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            let chunk = AVAudioFrameCount(format.sampleRate / 20)   // 50 ms
            var clock = Date()
            var trailing: TimeInterval = 0
            while !Task.isCancelled, trailing < 3 {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
                      let channels = buffer.floatChannelData else { break }
                if audio.framePosition < audio.length {
                    try? audio.read(into: buffer, frameCount: chunk)
                } else {
                    buffer.frameLength = chunk
                    for c in 0..<Int(format.channelCount) { channels[c].update(repeating: 0, count: Int(chunk)) }
                    trailing += Double(chunk) / format.sampleRate
                }
                guard buffer.frameLength > 0 else { break }
                uplink.push(buffer)
                let db = Uplink.decibels(buffer)
                self?.level = max(0, min(1, (db + 60) / 60))
                clock += Double(buffer.frameLength) / format.sampleRate
                try? await Task.sleep(for: .seconds(max(0, clock.timeIntervalSinceNow)))
            }
            guard !Task.isCancelled else { return }
            self?.onFileEnd?()
        }
    }

    // MARK: - Socket

    private func connect() {
        guard listening, let key = Self.key else { return }
        connection += 1
        session += 1
        let connection = self.connection
        status = "Connecting"
        speaker = nil
        turnStart = 0

        let socket = URLSession.shared.webSocketTask(with: Self.endpoint)
        self.socket = socket
        socket.resume()

        var handshake: [String: Any] = [
            "authorization": ["accessToken": "Bearer \(key)"],
            "audioEncoding": "PCM_24KHZ",
            "model": Self.model,
            "mode": Self.mode,
            "emitAudioProgress": false,
        ]
        if !keywords.isEmpty { handshake["keywords"] = keywords }

        reader = Task { [weak self] in
            do {
                let data = try JSONSerialization.data(withJSONObject: handshake)
                try await socket.send(.string(String(decoding: data, as: UTF8.self)))
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard case .string(let text) = message,
                          let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                    else { continue }
                    self?.received(json, on: connection, socket: socket)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.dropped(connection, reason: error.localizedDescription)
            }
        }
    }

    private func received(_ event: [String: Any], on connection: Int, socket: URLSessionWebSocketTask) {
        guard connection == self.connection else { return }
        let audioMs = (event["audioProcessedMs"] as? NSNumber)?.intValue ?? 0
        switch event["type"] as? String {
        case nil where event["sessionId"] != nil:
            // Handshake accepted: only now start streaming, or the server sees audio before config.
            uplink.use(socket)
            status = "Listening"
        case "speechStart":
            turnStart = audioMs
        case "speaker":
            // Arrives just before the turn's speechComplete; the last one before it names the turn.
            if let label = event["label"] as? String { speaker = session > 1 ? "\(label)\(session)" : label }
        case "transcript":
            guard let text = (event["transcript"] as? String)?.trimmed, !text.isEmpty, text != transcript else { return }
            transcript = text
            onPartial?(text)
        case "speechComplete":
            // The turn's final text, which can differ from the last partial.
            let text = (event["transcript"] as? String)?.trimmed ?? transcript
            transcript = ""
            let level = uplink.level(fromMs: turnStart, toMs: audioMs)
            if !text.isEmpty { onLine?(text, speaker, level) }
        case "error":
            status = "Transcription error: \(event["message"] as? String ?? "unknown")"
        default:
            break   // speechEnd / audioProgress, and anything new
        }
    }

    /// The socket closed under us. Flush whatever was pending and reconnect after a beat.
    private func dropped(_ connection: Int, reason: String) {
        guard connection == self.connection, listening else { return }
        uplink.use(nil)
        if !transcript.isEmpty {
            onLine?(transcript, nil, nil)
            transcript = ""
        }
        status = "Reconnecting (\(reason))"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.listening, connection == self.connection else { return }
            self.connect()
        }
    }
}

/// Converts audio buffers to 24 kHz mono 16-bit PCM and sends them in 80 ms binary frames, off the
/// realtime thread. The server rejects ingress slower than real time (close 1008, "Ingress audio
/// slower than real-time"), so audio flows the whole time the mic is on, silence included — and
/// if the mic stalls (route change, the OS throttling us), a pacer pads the gap with silence.
/// It also remembers each frame's loudness, so a turn's level can be read back by its audio time.
private final class Uplink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "muse.uplink", qos: .userInteractive)
    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private var pending = Data()
    private static let frameBytes = 24_000 * 2 * 80 / 1000
    private static let frameMs = 80
    private static let bytesPerSecond = 24_000.0 * 2
    /// Wall-clock start of the current socket's audio, and how much we have sent on it.
    private var startedAt = Date()
    private var sentBytes = 0
    /// dB of every frame sent on the current socket; index × 80 ms = the server's audioProcessedMs.
    private var levels: [Float] = []
    private lazy var pacer: DispatchSourceTimer = {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(80))
        timer.setEventHandler { [weak self] in self?.pad() }
        timer.resume()
        return timer
    }()

    var ready: Bool {
        lock.lock(); defer { lock.unlock() }
        return socket != nil
    }

    func prepare(from format: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: format, to: target) else {
            throw NSError(domain: "Listener", code: 1, userInfo: [NSLocalizedDescriptionKey: "Can't convert audio to 24 kHz PCM"])
        }
        queue.sync { self.converter = converter; pending.removeAll() }
    }

    func use(_ next: URLSessionWebSocketTask?) {
        lock.lock()
        socket = next
        levels.removeAll()
        lock.unlock()
        queue.async {
            self.pending.removeAll()
            self.startedAt = Date()
            self.sentBytes = 0
            _ = self.pacer
        }
    }

    /// Loudness of a stretch of the current socket's audio: the mean dB of its loudest 30% of
    /// frames, so the pauses around a short turn don't drag it down.
    func level(fromMs start: Int, toMs end: Int) -> Float? {
        lock.lock(); defer { lock.unlock() }
        let from = max(0, start / Self.frameMs), to = min(levels.count, end / Self.frameMs + 1)
        guard to - from >= 3 else { return nil }
        let loud = levels[from..<to].sorted(by: >).prefix(max(1, (to - from) * 3 / 10))
        return loud.reduce(0, +) / Float(loud.count)
    }

    /// More than 240 ms behind real time: the mic stalled, so send silence up to 80 ms behind.
    private func pad() {
        lock.lock()
        let socket = self.socket
        lock.unlock()
        guard let socket else { return }
        let expected = Int(Date().timeIntervalSince(startedAt) * Self.bytesPerSecond)
        guard expected - sentBytes > Self.frameBytes * 3 else { return }
        pending.removeAll()
        while expected - sentBytes > Self.frameBytes {
            socket.send(.data(Data(count: Self.frameBytes))) { _ in }
            sentBytes += Self.frameBytes
            record(-120)
        }
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        // The tap reuses its buffer once we return, so copy before crossing threads.
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for c in 0..<channels { dst[c].update(from: src[c], count: Int(buffer.frameLength)) }
        }
        queue.async { self.send(copy) }
    }

    private func send(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let socket = self.socket
        lock.unlock()
        guard let socket, let converter else { return }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let samples = out.int16ChannelData else { return }
        pending.append(Data(bytes: samples[0], count: Int(out.frameLength) * 2))

        while pending.count >= Self.frameBytes {
            let frame = Data(pending.prefix(Self.frameBytes))
            pending.removeFirst(Self.frameBytes)
            socket.send(.data(frame)) { _ in }   // failures surface on receive()
            sentBytes += Self.frameBytes
            record(Self.decibels(frame))
        }
    }

    private func record(_ db: Float) {
        lock.lock()
        levels.append(db)
        lock.unlock()
    }

    static func decibels(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return -120 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return -120 }
        var sum: Float = 0
        for i in 0..<frames { sum += data[i] * data[i] }
        return 10 * log10(max(sum / Float(frames), 1e-12))
    }

    /// RMS of a 16-bit little-endian PCM frame, in dB full scale.
    private static func decibels(_ frame: Data) -> Float {
        frame.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return -120 }
            var sum: Float = 0
            for s in samples { let v = Float(s) / 32768; sum += v * v }
            return 10 * log10(max(sum / Float(samples.count), 1e-12))
        }
    }
}
