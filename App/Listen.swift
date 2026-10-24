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
    /// When the file's first audio went out: time zero of the recording, for lining up traces.
    @ObservationIgnored private(set) var fileStarted: Date?
    /// Which microphone to use (iOS).
    /// - `phone` (default): the iPhone's own mic. Never opens Bluetooth audio.
    /// - `glasses`: the glasses' mic, delivered by the host through `feed(_:)` (the Meta SDK's
    ///   camera-stream audio), so iOS's audio route is never touched. If that audio stops arriving
    ///   for 4 s, the phone mic covers until it's back.
    /// The Bluetooth hands-free route to the glasses' mic is not used: on Toby's pair it flapped
    /// every few seconds (each flap ~4 s of renegotiation), halved the camera frame rate and made a
    /// lens write take 18 s.
    enum Mic: String { case glasses, phone }
    @ObservationIgnored var mic: Mic = .phone {
        didSet { uplink.glassesMode = mic == .glasses }
    }
    /// The input actually in use, e.g. "Ray-Ban Meta (Bluetooth)" or "iPhone Microphone".
    var input = ""
    /// Diagnostics for the host's log (the app's speed.jsonl): audio restarts, route, socket.
    @ObservationIgnored var onLog: (([String: Any]) -> Void)?
    #if os(iOS)
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var micWatch: Task<Void, Never>?
    @ObservationIgnored private var restarting = false
    /// Our own restart changes the route and the engine's configuration, which posts the very
    /// notifications that trigger a restart. Ignore those for a moment, or it loops.
    @ObservationIgnored private var lastRestart = Date.distantPast
    #endif

    static let model = "muse-voice-transcribe-1.0"
    static let mode = "DIARIZATION"
    /// The remembered mic. `MIC=glasses` / `MIC=phone` from Xcode or devicectl wins and is stored,
    /// so the choice can be made without the phone's menu.
    static var storedMic: Mic {
        if let forced = ProcessInfo.processInfo.environment["MIC"].flatMap(Mic.init(rawValue:)) {
            UserDefaults.standard.set(forced.rawValue, forKey: "mic")
            return forced
        }
        return Mic(rawValue: UserDefaults.standard.string(forKey: "mic") ?? "") ?? .phone
    }

    static let endpoint = URL(string: "wss://api.meta.ai/v1/asr/realtime")!

    /// Set `MUSE_API_KEY` in Secrets.xcconfig (see Secrets.example.xcconfig).
    static var key: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "MuseAPIKey") as? String
        return (value?.isEmpty == false) ? value : nil
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let uplink = Uplink()
    /// Loudness at each mic over the last minute, sent or not. With the glasses' mic on, the phone's
    /// keeps running underneath, and the gap between the two is the best wearer signal sound alone
    /// gives: the wearer's mouth is centimetres from the glasses and a metre from the phone, the
    /// other person is about as far from both.
    @ObservationIgnored let meter = LevelMeter()
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
            // The phone mic always runs, even in glasses mode: its buffers are simply not sent while
            // the glasses' are arriving. Starting it later as a fallback failed (OSStatus '!int',
            // can't start recording from the background), so it starts here, in the foreground.
            try await startAudio()
            if mic == .glasses { input = "Glasses mic" }
            listening = true
            #if os(iOS)
            watchAudio()
            #endif
            connect()
        } catch {
            status = "Audio failed: \(error.localizedDescription)"
            stop()
        }
    }

    /// Session, route and tap, from scratch. Called on start and whenever the mic really stopped.
    private func startAudio() async throws {
        #if os(iOS)
        // Off the main thread: with a Bluetooth input these calls block for seconds while the
        // route renegotiates, and on the main thread that froze the whole app.
        input = try await Task.detached(priority: .userInitiated) { try Self.configureSession(.phone) }.value
        #endif

        if engine.isRunning { engine.stop() }
        let node = engine.inputNode
        node.removeTap(onBus: 0)
        // format nil = whatever the hardware delivers right now. Passing the format we had read a
        // moment earlier crashed the app (NSException in installTap, 10:47) when the route changed
        // the sample rate in between; the uplink adapts to each buffer's format instead.
        // Realtime audio thread: hand the buffer to the uplink (it converts and sends off this
        // thread) and send only a level reading to the main actor.
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self, uplink = self.uplink, meter = self.meter] buffer, _ in
            let db = Uplink.decibels(buffer)
            meter.record(.phone, db)
            guard uplink.pushPhone(buffer) else { return }
            Task { @MainActor in self?.level = max(0, min(1, (db + 60) / 60)) }
        }
        uplink.inputStarted()
        engine.prepare()
        try engine.start()
        onLog?(["event": "micStart", "input": input, "rate": Int(node.outputFormat(forBus: 0).sampleRate)])
    }

    #if os(iOS)
    /// Returns the name of the input in use.
    nonisolated private static func configureSession(_ mic: Mic) throws -> String {
        let session = AVAudioSession.sharedInstance()
        // .mixWithOthers so the glasses' own audio never takes the mic away from us; no
        // .allowBluetooth, so iOS never moves the input to the glasses' hands-free route.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let headset = session.availableInputs?.first { $0.portType == .bluetoothHFP }
        let builtIn = session.availableInputs?.first { $0.portType == .builtInMic }
        try? session.setPreferredInput(mic == .glasses ? (headset ?? builtIn) : builtIn)
        let current = session.currentRoute.inputs.first
        var name = current.map { $0.portType == .bluetoothHFP ? "\($0.portName) (Bluetooth)" : $0.portName } ?? "No microphone"
        if mic == .glasses, headset == nil { name += " · glasses mic not available" }
        return name
    }
    #endif

    #if os(iOS)
    /// iOS stops the engine without telling the tap: an interruption, a route change (the glasses
    /// connecting over Bluetooth, a reconnect), a configuration change, a media-services reset. The
    /// uplink then padded silence forever, so Muse stayed connected and heard nothing: "listening"
    /// and deaf. Every one of those now restarts the audio, and a watchdog catches anything else
    /// (no mic buffer for 2 s).
    private func watchAudio() {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        let session = AVAudioSession.sharedInstance()
        let names: [(Notification.Name, AnyObject?)] = [
            (.AVAudioEngineConfigurationChange, engine),
            (AVAudioSession.interruptionNotification, session),
            (AVAudioSession.routeChangeNotification, session),
            (AVAudioSession.mediaServicesWereResetNotification, session),
        ]
        observers = names.map { name, object in
            center.addObserver(forName: name, object: object, queue: .main) { [weak self] note in
                let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
                let reason = note.name.rawValue
                MainActor.assumeIsolated {
                    guard let self, self.listening, self.file == nil else { return }
                    if began {
                        self.status = "Mic interrupted"
                        self.onLog?(["event": "micInterrupted"])
                        return
                    }
                    // A notification is only a hint. Restarting on every route change looped:
                    // each restart changed the route again (19 restarts in a minute, app frozen).
                    // Restart only if the mic actually stopped delivering.
                    self.checkSoon(reason: reason)
                }
            }
        }
        micWatch?.cancel()
        micWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.listening, self.file == nil else { continue }
                if self.mic == .glasses { self.noteCover() }
                if self.micDead { await self.restartAudio(reason: "micStalled") }
            }
        }
    }

    private var micDead: Bool { !engine.isRunning || uplink.secondsSinceInput > 2 }

    /// Glasses mode: say which mic is actually being sent. The switch itself is per buffer, in
    /// the uplink: glasses audio when it's fresh, the phone's when it isn't.
    private func noteCover() {
        let covering = uplink.secondsSinceExternal > 1
        let label = covering ? "iPhone Microphone · glasses audio not arriving" : "Glasses mic"
        guard label != input else { return }
        input = label
        onLog?(["event": "micCover", "on": covering])
    }

    /// The glasses' mic, from any thread: the Meta SDK's stream audio callback.
    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        let db = Uplink.decibels(buffer)
        meter.record(.glasses, db)
        guard uplink.pushExternal(buffer) else { return }
        Task { @MainActor [weak self] in self?.level = max(0, min(1, (db + 60) / 60)) }
    }

    private func checkSoon(reason: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.listening, self.micDead else { return }
            await self.restartAudio(reason: reason)
        }
    }

    /// At most one restart in flight, and spaced out (5 s, doubling to 30 s while they keep
    /// failing to stick) so nothing can spin.
    @ObservationIgnored private var restartGap: TimeInterval = 5

    private func restartAudio(reason: String) async {
        guard !restarting else { return }
        let since = Date().timeIntervalSince(lastRestart)
        guard since >= restartGap else { return }
        restartGap = since < 30 ? min(restartGap * 2, 30) : 5
        restarting = true
        lastRestart = Date()
        defer { restarting = false }
        let before = input
        do {
            try await startAudio()
            if socket != nil, status.hasPrefix("Mic") { status = "Listening" }
            onLog?(["event": "micRestart", "reason": reason, "from": before, "to": input])
        } catch {
            status = "Mic failed: \(error.localizedDescription)"
            onLog?(["event": "micRestartFailed", "reason": reason, "error": error.localizedDescription])
        }
    }

    /// Switch microphones while listening.
    func use(_ mic: Mic) {
        guard mic != self.mic else { return }
        self.mic = mic
        lastRestart = .distantPast
        restartGap = 5
        uplink.glassesMode = mic == .glasses
        guard listening, file == nil else { return }
        // The phone mic keeps running either way; only which buffers are sent changes.
        if mic == .glasses {
            input = "Glasses mic"
            uplink.markExternal()
        } else {
            input = input.hasPrefix("iPhone") || input.hasPrefix("Glasses") ? "iPhone Microphone" : input
        }
        onLog?(["event": "micChosen", "mic": mic.rawValue])
    }
    #endif

    func stop() {
        #if os(iOS)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        micWatch?.cancel()
        micWatch = nil
        #endif
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
            self?.fileStarted = clock
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
            onLog?(["event": "museConnected", "input": input]) 
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
            onLog?(["event": "museError", "message": event["message"] as? String ?? "unknown"])
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
        onLog?(["event": "museDropped", "reason": reason])
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.listening, connection == self.connection else { return }
            self.connect()
        }
    }
}

/// Loudness per mic over time, from any thread.
final class LevelMeter: @unchecked Sendable {
    enum Source { case glasses, phone }
    private let lock = NSLock()
    private var samples: [Source: [(at: Date, db: Float)]] = [:]

    func record(_ source: Source, _ db: Float, at now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var list = samples[source] ?? []
        list.append((now, db))
        if let first = list.first, now.timeIntervalSince(first.at) > 90 {
            list.removeFirst(list.firstIndex { now.timeIntervalSince($0.at) <= 60 } ?? list.count)
        }
        samples[source] = list
    }

    /// Mean dB of the loudest 30% of a stretch (pauses don't drag a short turn down); nil when the
    /// mic sent nothing then.
    func level(_ source: Source, from start: Date, to end: Date) -> Float? {
        lock.lock(); defer { lock.unlock() }
        let span = (samples[source] ?? []).filter { $0.at >= start && $0.at <= end && $0.db > -100 }.map(\.db)
        guard span.count >= 5 else { return nil }
        let loud = span.sorted(by: >).prefix(max(1, span.count * 3 / 10))
        return loud.reduce(0, +) / Float(loud.count)
    }

    /// Glasses minus phone over a stretch: large for the wearer, small for everyone else.
    func gap(from start: Date, to end: Date) -> Float? {
        guard let glasses = level(.glasses, from: start, to: end), let phone = level(.phone, from: start, to: end) else { return nil }
        return glasses - phone
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
        inputStarted()
    }

    /// A (re)started mic gets a fresh 2 s before the stall watchdog judges it.
    func inputStarted() {
        lock.lock(); lastInput = Date(); lock.unlock()
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

    /// Wall-clock of the last mic buffer, for the stall watchdog. Silence padding doesn't count.
    private var lastInput = Date()
    /// Glasses mode: the glasses' buffers (`pushExternal`) are sent while they keep coming; the
    /// phone's (`pushPhone`) only once they've been missing for a second. One source at a time,
    /// or the stream would run faster than real time.
    private var _glassesMode = false
    private var lastExternal = Date.distantPast
    var glassesMode: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _glassesMode }
        set { lock.lock(); _glassesMode = newValue; lock.unlock() }
    }
    var secondsSinceExternal: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastExternal)
    }
    func markExternal() { lock.lock(); lastExternal = Date(); lock.unlock() }

    /// A buffer from the glasses; sent in glasses mode. Returns whether it was used.
    @discardableResult
    func pushExternal(_ buffer: AVAudioPCMBuffer) -> Bool {
        lock.lock()
        lastExternal = Date()
        let use = _glassesMode
        lock.unlock()
        if use { push(buffer) }
        return use
    }

    /// A buffer from the phone's mic; sent unless fresh glasses audio is. Returns whether it was used.
    @discardableResult
    func pushPhone(_ buffer: AVAudioPCMBuffer) -> Bool {
        lock.lock()
        let use = !_glassesMode || Date().timeIntervalSince(lastExternal) > 1
        lock.unlock()
        if use { push(buffer) } else { lock.lock(); lastInput = Date(); lock.unlock() }
        return use
    }
    var secondsSinceInput: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastInput)
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); lastInput = Date(); lock.unlock()
        // The tap reuses its buffer once we return, so copy before crossing threads.
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        // Any sample format (the phone sends float, the glasses 16-bit): copy the raw buffers.
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            if let from = s.mData, let to = d.mData { memcpy(to, from, Int(min(s.mDataByteSize, d.mDataByteSize))) }
        }
        queue.async { self.send(copy) }
    }

    private func send(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let socket = self.socket
        lock.unlock()
        guard let socket else { return }
        // The mic's format follows the route (48 kHz phone, 16 kHz Bluetooth); follow it.
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            pending.removeAll()
        }
        guard let converter else { return }

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
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return -120 }
        var sum: Float = 0
        if let data = buffer.floatChannelData?[0] {
            for i in 0..<frames { sum += data[i] * data[i] }
        } else if let data = buffer.int16ChannelData?[0] {
            for i in 0..<frames { let v = Float(data[i]) / 32768; sum += v * v }
        } else {
            return -120
        }
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
