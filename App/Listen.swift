import AVFoundation
import Foundation
import Observation

/// Continuous phone-mic listening, transcribed by Meta's Muse Voice Transcribe over its realtime
/// websocket (wss://api.meta.ai/v1/asr/realtime).
///
/// The server does the hard parts: it streams cumulative partials ~100-300 ms behind the audio and
/// decides where a turn ends (`speechComplete`), so there is no local endpointing and no
/// per-utterance recognizer to rotate. One socket stays open for the whole conversation; if the
/// server ends it (max session length, network blip) we open another.
@MainActor @Observable final class Listener {
    var transcript = ""
    var listening = false
    var level: Float = 0
    var status = "Idle"

    /// Every new hypothesis for the current utterance. `endpointed` means the turn is over.
    @ObservationIgnored var onUpdate: ((_ text: String, _ endpointed: Bool) -> Void)?
    /// Words to bias recognition toward, e.g. the names of the people in the room.
    @ObservationIgnored var keywords: [String] = []

    static let model = "muse-voice-transcribe-1.0"
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
    /// Bumped per socket so events from a dead one are ignored.
    @ObservationIgnored private var connection = 0

    func start() async {
        guard !listening else { return }
        guard Self.key != nil else {
            status = "No Muse API key — add MUSE_API_KEY to Secrets.xcconfig"
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            status = "Mic permission denied"
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
            status = "Mic failed: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        connection += 1
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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Socket

    private func connect() {
        guard listening, let key = Self.key else { return }
        connection += 1
        let connection = self.connection
        status = "Connecting"

        let socket = URLSession.shared.webSocketTask(with: Self.endpoint)
        self.socket = socket
        socket.resume()

        var handshake: [String: Any] = [
            "authorization": ["accessToken": "Bearer \(key)"],
            "audioEncoding": "PCM_24KHZ",
            "model": Self.model,
            "mode": "ENDPOINTING",
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
        switch event["type"] as? String {
        case nil where event["sessionId"] != nil:
            // Handshake accepted: only now start streaming, or the server sees audio before config.
            uplink.use(socket)
            status = "Listening"
        case "transcript":
            guard let text = (event["transcript"] as? String)?.trimmed, !text.isEmpty, text != transcript else { return }
            transcript = text
            onUpdate?(text, false)
        case "speechComplete":
            // The turn's final text, which can differ from the last partial.
            let text = (event["transcript"] as? String)?.trimmed ?? transcript
            transcript = ""
            if !text.isEmpty { onUpdate?(text, true) }
        case "error":
            status = "Transcription error: \(event["message"] as? String ?? "unknown")"
        default:
            break   // speechStart / speechEnd / speaker / audioProgress, and anything new
        }
    }

    /// The socket closed under us. Flush whatever was pending and reconnect after a beat.
    private func dropped(_ connection: Int, reason: String) {
        guard connection == self.connection, listening else { return }
        uplink.use(nil)
        if !transcript.isEmpty {
            onUpdate?(transcript, true)
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

/// Converts mic buffers to 24 kHz mono 16-bit PCM and sends them in 80 ms binary frames, off the
/// realtime thread. The server rejects ingress slower than real time (close 1008), so audio flows
/// the whole time the mic is on, silence included.
private final class Uplink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "muse.uplink", qos: .userInteractive)
    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private var pending = Data()
    private static let frameBytes = 24_000 * 2 * 80 / 1000

    func prepare(from format: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: format, to: target) else {
            throw NSError(domain: "Listener", code: 1, userInfo: [NSLocalizedDescriptionKey: "Can't convert mic audio to 24 kHz PCM"])
        }
        queue.sync { self.converter = converter; pending.removeAll() }
    }

    func use(_ next: URLSessionWebSocketTask?) {
        lock.lock()
        socket = next
        lock.unlock()
        queue.async { self.pending.removeAll() }
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
            let frame = pending.prefix(Self.frameBytes)
            pending.removeFirst(Self.frameBytes)
            socket.send(.data(Data(frame))) { _ in }   // failures surface on receive()
        }
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
