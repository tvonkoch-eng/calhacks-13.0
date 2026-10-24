import AVFoundation
import Foundation
import Speech
import CoreAudio

// Live side-by-side evaluation on a Mac. One mic, several engines at once:
//
//   Speech-to-text  MUSE (Muse Voice Transcribe, drives question detection) · APPLE (on-device
//                   SFSpeech, the app's old engine) · WHISPER (Groq whisper-large-v3, per utterance)
//                   · DEEPGRAM (Nova-3 streaming, only if DEEPGRAM_API_KEY is set)
//   Answers         moss (instant lookup, learns every answer) · groq · muse, raced on each question
//
// Every transcript line shows how long after you stopped talking it arrived (+ms); every answer
// shows time to its first word. Ctrl-C prints medians. Built by tools/live-mac.sh against the app's
// own Question.swift, Answer.swift and Uplink, so question detection and answering are the phone's.

func info(_ key: String) -> String {
    (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
}
let museKey = info("MuseAPIKey"), groqKey = info("GroqAPIKey"), deepgramKey = info("DeepgramAPIKey")
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 600
let names = ["Joaquin", "Mirabelle", "Avi", "Toby", "Haystack", "Cal Hacks"]
let t0 = Date()

func stamp() -> String { String(format: "%6.2f", Date().timeIntervalSince(t0)) }
func clearLine() { print("\r\u{1B}[2K", terminator: "") }
func say(_ s: String) { clearLine(); print("\(stamp())  \(s)"); fflush(stdout) }
func ms(_ d: TimeInterval) -> Int { Int((d * 1000).rounded()) }
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

// MARK: - Results

@MainActor final class Tally {
    static var stt: [String: [Int]] = [:]
    static var answers: [String: [Int]] = [:]
    static var mossHits = 0, questions = 0

    static func summary() {
        func median(_ xs: [Int]) -> String {
            guard !xs.isEmpty else { return "—" }
            return "\(xs.sorted()[xs.count / 2]) ms"
        }
        print("")
        say("SUMMARY  \(questions) questions, \(mossHits) answered by moss from memory")
        for (name, lags) in stt.sorted(by: { $0.key < $1.key }) {
            say("  stt     \(pad(name, 8)) median +\(median(lags)) after you stopped (\(lags.count) utterances)")
        }
        for (name, firsts) in answers.sorted(by: { $0.key < $1.key }) {
            say("  answer  \(pad(name, 8)) median first word \(median(firsts)) (\(firsts.count) answers)")
        }
    }
}

// MARK: - Voice activity: when did they actually stop talking?

/// Runs on the audio thread; publishes the last moment the mic heard voice.
final class VoiceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var floor: Float = -50
    private var last = Date.distantPast
    private var loudest: Float = -120
    private var buffers = 0
    private var peaks: [Float] = []
    var lastVoice: Date { lock.lock(); defer { lock.unlock() }; return last }
    /// False when every buffer is digital silence, which is what a mic without permission delivers.
    var heardAnything: Bool { lock.lock(); defer { lock.unlock() }; return loudest > -100 }
    /// "212 buffers, peak per channel: -38 dB, -120 dB"
    var report: String {
        lock.lock(); defer { lock.unlock() }
        let p = peaks.map { String(format: "%.0f dB", 20 * log10(max($0, 1e-6))) }.joined(separator: ", ")
        return "\(buffers) buffers, peak per channel: \(p.isEmpty ? "none" : p)"
    }

    /// Returns whether this buffer is voiced.
    @discardableResult func measure(_ buffer: AVAudioPCMBuffer) -> Bool {
        lock.lock(); buffers += 1; lock.unlock()
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return false }
        let n = Int(buffer.format.channelCount), frames = Int(buffer.frameLength)
        // Loudest channel wins: on a multi-channel input, channel 0 alone can be silent.
        var sum: Float = 0
        var channelPeaks = [Float](repeating: 0, count: n)
        for c in 0..<n {
            var s: Float = 0
            for i in 0..<frames { let v = channels[c][i]; s += v * v; channelPeaks[c] = max(channelPeaks[c], abs(v)) }
            sum = max(sum, s)
        }
        let db = 10 * log10(max(sum / Float(frames), 1e-12))
        lock.lock(); defer { lock.unlock() }
        if peaks.count != n { peaks = channelPeaks } else { for c in 0..<n { peaks[c] = max(peaks[c], channelPeaks[c]) } }
        loudest = max(loudest, db)
        let voiced = db > floor + 8
        if voiced { last = Date() } else { floor = min(-25, max(-60, floor * 0.98 + db * 0.02)) }
        return voiced
    }
}

let clock = VoiceClock()

@MainActor func heard(_ engine: String, _ text: String) {
    let lag = ms(Date().timeIntervalSince(clock.lastVoice))
    Tally.stt[engine, default: []].append(lag)
    say("\(pad(engine, 8)) \(pad(text, 70))  +\(lag) ms")
}

// MARK: - Answers: moss vs groq vs muse on every question

@MainActor final class Answers {
    var fired = ""
    var generation = 0
    var tasks: [Task<Void, Never>] = []
    var refused = false

    func partial(_ text: String) {
        guard let c = QuestionGate.candidate(in: text), c.confidence == .strong else { return }
        if shouldFire(c.text) { fire(c.text, why: "mid-sentence") }
    }

    func complete(_ text: String) {
        defer { fired = ""; refused = false }
        guard let c = QuestionGate.candidate(in: text) else { return }
        if shouldFire(c.text) { fire(c.text, why: "at turn end") }
    }

    private func shouldFire(_ text: String) -> Bool {
        if fired.isEmpty { return true }
        let grew = text.split(separator: " ").count - fired.split(separator: " ").count
        return text != fired && (grew >= 2 || refused)
    }

    func fire(_ question: String, why: String) {
        tasks.forEach { $0.cancel() }
        tasks = []
        generation += 1
        let generation = self.generation
        fired = question
        refused = false
        Tally.questions += 1
        let start = Date()
        say("ASK      \"\(question)\"  (\(why))")

        if let instant = Answerer.local(question) {
            say("  local  \(instant)  [0 ms]")
            return
        }

        tasks.append(Task {
            guard let hit = await Moss.lookup(question), generation == self.generation else { return }
            if hit.hit {
                Tally.mossHits += 1
                Tally.answers["moss", default: []].append(ms(Date().timeIntervalSince(start)))
                say("  moss   \(hit.answer)  [\(String(format: "%.1f", hit.ms)) ms search, matched \"\(hit.question)\" @ \(String(format: "%.2f", hit.score))]")
            } else {
                say("  moss   miss  [\(String(format: "%.1f", hit.ms)) ms]")
            }
        })

        var racers: [(String, Provider, String, String)] = []
        if !groqKey.isEmpty { racers.append(("groq", .groq, groqKey, Provider.groq.model)) }
        if !museKey.isEmpty { racers.append(("muse", .muse, museKey, Provider.muse.model)) }
        for (name, provider, key, model) in racers {
            tasks.append(Task {
                var answer = "", first: Int?
                do {
                    for try await partial in Answerer.stream(question, provider: provider, key: key, model: model) {
                        if Task.isCancelled { return }
                        if first == nil { first = ms(Date().timeIntervalSince(start)) }
                        answer = partial
                    }
                } catch {
                    if !Task.isCancelled { say("  \(pad(name, 6)) FAIL \(error.localizedDescription)") }
                    return
                }
                guard !Task.isCancelled, generation == self.generation else { return }
                let done = ms(Date().timeIntervalSince(start))
                if let first, !answer.isEmpty {
                    Tally.answers[name, default: []].append(first)
                    say("  \(pad(name, 6)) \(pad(answer, 52)) first word \(first) ms, done \(done) ms")
                    await Moss.learn(question, answer)
                } else {
                    self.refused = true
                    say("  \(pad(name, 6)) SKIP (personal / rhetorical)  [\(done) ms]")
                }
            })
        }
    }
}

enum Moss {
    struct Hit: Decodable { let hit: Bool; let ms: Double; let score: Double?; let question: String?; let answer: String?
        var hitAnswer: String { answer ?? "" } }
    static let base = URL(string: "http://127.0.0.1:\(ProcessInfo.processInfo.environment["MOSS_PORT"] ?? "8765")")!
    private static var learned = Set<String>()

    static func lookup(_ q: String) async -> (hit: Bool, ms: Double, score: Double, question: String, answer: String)? {
        var url = URLComponents(url: base.appendingPathComponent("q"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "text", value: q)]
        guard let (data, _) = try? await URLSession.shared.data(from: url.url!),
              let h = try? JSONDecoder().decode(Hit.self, from: data) else { return nil }
        return (h.hit, h.ms, h.score ?? 0, h.question ?? "", h.hitAnswer)
    }

    /// First good answer per question goes into the index, so a reworded repeat is instant.
    @MainActor static func learn(_ q: String, _ a: String) async {
        guard learned.insert(q).inserted else { return }
        var request = URLRequest(url: base.appendingPathComponent("add"))
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["q": q, "a": a])
        _ = try? await URLSession.shared.data(for: request)
    }
}

let answers = MainActor.assumeIsolated { Answers() }

// MARK: - STT lane: Muse (primary)

@MainActor final class MuseLane {
    let uplink = Uplink()
    var partialText = ""
    var connected = false

    func connect() {
        let socket = URLSession.shared.webSocketTask(with: URL(string: "wss://api.meta.ai/v1/asr/realtime")!)
        socket.resume()
        let handshake: [String: Any] = [
            "authorization": ["accessToken": "Bearer \(museKey)"], "audioEncoding": "PCM_24KHZ",
            "model": "muse-voice-transcribe-1.0", "mode": "ENDPOINTING", "emitAudioProgress": false, "keywords": names,
        ]
        Task {
            do {
                try await socket.send(.string(String(decoding: try JSONSerialization.data(withJSONObject: handshake), as: UTF8.self)))
                while true {
                    guard case .string(let text) = try await socket.receive(),
                          let event = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                    switch event["type"] as? String {
                    case nil:
                        uplink.use(socket)
                        connected = true
                        say("MUSE     connected — go ahead and talk")
                    case "transcript":
                        guard let t = (event["transcript"] as? String)?.trimmed, !t.isEmpty, t != partialText else { continue }
                        partialText = t
                        clearLine(); print("\(stamp())  …        \(t.suffix(110))", terminator: ""); fflush(stdout)
                        answers.partial(t)
                    case "speechComplete":
                        partialText = ""
                        guard let t = (event["transcript"] as? String)?.trimmed, !t.isEmpty else { continue }
                        heard("MUSE", t)
                        answers.complete(t)
                    case "error": say("MUSE     error: \(event["message"] ?? "")")
                    default: break
                    }
                }
            } catch {
                uplink.use(nil)
                say("MUSE     socket closed (\(error.localizedDescription)) — reconnecting")
                try? await Task.sleep(for: .seconds(1))
                connect()
            }
        }
    }
}

// MARK: - STT lane: Deepgram Nova-3 (optional)

@MainActor final class DeepgramLane {
    let uplink = Uplink()
    var turn: [String] = []

    func connect() {
        var url = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        url.queryItems = [
            .init(name: "model", value: "nova-3"), .init(name: "encoding", value: "linear16"),
            .init(name: "sample_rate", value: "24000"), .init(name: "channels", value: "1"),
            .init(name: "interim_results", value: "true"), .init(name: "endpointing", value: "300"),
            .init(name: "smart_format", value: "true"),
        ] + names.map { .init(name: "keyterm", value: $0) }
        var request = URLRequest(url: url.url!)
        request.setValue("Token \(deepgramKey)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        uplink.use(socket)
        Task {
            do {
                while true {
                    guard case .string(let text) = try await socket.receive(),
                          let event = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                          event["type"] as? String == "Results",
                          let alt = ((event["channel"] as? [String: Any])?["alternatives"] as? [[String: Any]])?.first,
                          let t = alt["transcript"] as? String else { continue }
                    if event["is_final"] as? Bool == true, !t.isEmpty { turn.append(t) }
                    if event["speech_final"] as? Bool == true, !turn.isEmpty {
                        heard("DEEPGRAM", turn.joined(separator: " "))
                        turn = []
                    }
                }
            } catch {
                uplink.use(nil)
                say("DEEPGRAM socket closed (\(error.localizedDescription)) — reconnecting")
                try? await Task.sleep(for: .seconds(1))
                connect()
            }
        }
    }
}

// MARK: - STT lane: Apple on-device (what the app used before)

@MainActor final class AppleLane {
    let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    nonisolated(unsafe) var request: SFSpeechAudioBufferRecognitionRequest?
    var task: SFSpeechRecognitionTask?
    var text = "", changedAt = Date()

    func start() async -> String? {
        let status = await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) } }
        guard status == .authorized else { return "speech recognition not authorized (System Settings → Privacy → Speech Recognition)" }
        guard let recognizer, recognizer.isAvailable else { return "recognizer unavailable" }
        rotate()
        // Same endpointing the app used: 320 ms with no voice and no transcript growth.
        Task {
            while true {
                try? await Task.sleep(for: .milliseconds(60))
                let quiet = Date().timeIntervalSince(max(clock.lastVoice, changedAt))
                if !text.isEmpty, quiet > 0.32 { flush() }
            }
        }
        return nil
    }

    func rotate() {
        task?.cancel()
        request?.endAudio()
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = true
        next.requiresOnDeviceRecognition = recognizer?.supportsOnDeviceRecognition ?? false
        next.addsPunctuation = true
        next.contextualStrings = names
        request = next
        text = ""
        task = recognizer?.recognitionTask(with: next) { [weak self] result, error in
            let t = result?.bestTranscription.formattedString
            let closed = result?.isFinal == true || error != nil
            Task { @MainActor in
                guard let self else { return }
                if let t, !t.isEmpty, t != self.text { self.text = t; self.changedAt = Date() }
                if closed { self.flush() }
            }
        }
    }

    func flush() {
        let t = text
        rotate()
        if !t.isEmpty { heard("APPLE", t) }
    }
}

// MARK: - STT lane: Groq Whisper, one request per utterance

/// Cuts the mic into utterances (300 ms pre-roll, ends after 500 ms of quiet) as 16 kHz WAV.
final class Utterances: @unchecked Sendable {
    private let queue = DispatchQueue(label: "utterances")
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var preroll = Data(), current = Data()
    private var speaking = false, quietSince: Date?
    var onUtterance: (@Sendable (Data) -> Void)?

    func prepare(from format: AVAudioFormat) { converter = AVAudioConverter(from: format, to: target) }

    func push(_ buffer: AVAudioPCMBuffer, voiced: Bool) {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let src = buffer.floatChannelData, let dst = copy.floatChannelData else { return }
        copy.frameLength = buffer.frameLength
        for c in 0..<Int(buffer.format.channelCount) { dst[c].update(from: src[c], count: Int(buffer.frameLength)) }
        queue.async { self.ingest(copy, voiced: voiced) }
    }

    private func ingest(_ buffer: AVAudioPCMBuffer, voiced: Bool) {
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) / 3) + 32) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard let samples = out.int16ChannelData else { return }
        let pcm = Data(bytes: samples[0], count: Int(out.frameLength) * 2)
        if voiced {
            if !speaking { speaking = true; current = preroll }
            quietSince = nil
        }
        if speaking {
            current.append(pcm)
            if !voiced {
                if quietSince == nil { quietSince = Date() }
                if Date().timeIntervalSince(quietSince!) > 0.5 || current.count > 16_000 * 2 * 30 {
                    speaking = false
                    if current.count > 16_000 * 2 * 6 / 10 { onUtterance?(Self.wav(current)) }   // > 0.6 s
                    current = Data()
                }
            }
        }
        preroll.append(pcm)
        if preroll.count > 9_600 { preroll.removeFirst(preroll.count - 9_600) }
    }

    static func wav(_ pcm: Data) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count)); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }
}

enum Whisper {
    static func transcribe(_ wav: Data) async -> String? {
        let boundary = UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", "whisper-large-v3")
        field("language", "en")
        field("prompt", names.joined(separator: ", "))
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"u.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(groqKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let t = json["text"] as? String { return t.trimmed }
        return "error: \(String(decoding: data.prefix(160), as: UTF8.self))"
    }
}

// MARK: - Main

/// The default input device's name, e.g. "MacBook Pro Microphone" or "AirPods Pro".
func inputName() -> String {
    var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return "unknown input" }
    var name: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    address.mSelector = kAudioObjectPropertyName
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return "unknown input" }
    return name.takeRetainedValue() as String
}

/// Global on purpose: run() returns once everything is started, and an engine that goes out of
/// scope stops delivering audio without any error.
let engine = AVAudioEngine()
var lanes: [AnyObject] = []

@MainActor func run() async throws {
    guard !museKey.isEmpty else { print("No MUSE_API_KEY in Secrets.xcconfig"); exit(1) }
    // Without this, macOS can throttle a terminal process in the background — a stalled mic
    // looks like "Ingress audio slower than real-time" to the Muse server.
    let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "live mic")
    _ = activity

    let format = engine.inputNode.outputFormat(forBus: 0)
    let muse = MuseLane()
    let deepgram = deepgramKey.isEmpty ? nil : DeepgramLane()
    let apple = AppleLane()
    let utterances = Utterances()
    try muse.uplink.prepare(from: format)
    try deepgram?.uplink.prepare(from: format)
    utterances.prepare(from: format)
    if !groqKey.isEmpty {
        utterances.onUtterance = { wav in
            Task { @MainActor in
                if let t = await Whisper.transcribe(wav), !t.isEmpty { heard("WHISPER", t) }
            }
        }
    }

    engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [museUp = muse.uplink, dgUp = deepgram?.uplink] buffer, _ in
        let voiced = clock.measure(buffer)
        museUp.push(buffer)
        dgUp?.push(buffer)
        apple.request?.append(buffer)
        utterances.push(buffer, voiced: voiced)
    }
    try engine.start()
    lanes = [muse, apple, utterances] + (deepgram.map { [$0] } ?? [])

    say("Listening \(Int(seconds)) s on the \(Int(format.sampleRate)) Hz mic. Talk normally; Ctrl-C for the summary.")
    say("stt      MUSE (drives questions) · APPLE" + (groqKey.isEmpty ? "" : " · WHISPER")
        + (deepgram == nil ? "   (DEEPGRAM off: no DEEPGRAM_API_KEY)" : " · DEEPGRAM"))
    say("answers  moss · " + [groqKey.isEmpty ? nil : "groq \(Provider.groq.model)", "muse \(Provider.muse.model)"].compactMap { $0 }.joined(separator: " · "))
    // Muse first: nothing else may hold it up. Apple's lane waits on a permission prompt that can
    // sit unanswered (or never appear for a terminal), so it starts on its own.
    muse.connect()
    deepgram?.connect()
    Task {
        try? await Task.sleep(for: .seconds(4))
        if !muse.connected { say("MUSE     still not connected after 4 s — check the network / MUSE_API_KEY") }
        else if !clock.heardAnything { say("MIC      no sound reaching the tool (\(clock.report)) — allow your terminal in System Settings → Privacy & Security → Microphone, then rerun") }
        say("MIC      \(inputName()) · \(format.channelCount) ch @ \(Int(format.sampleRate)) Hz · \(clock.report)")
    }
    Task {
        if let problem = await apple.start() { say("APPLE    off: \(problem)") }
    }
    if await Moss.lookup("ping") == nil { say("moss     sidecar not reachable — moss answers off") }

    Task {
        try? await Task.sleep(for: .seconds(seconds))
        Tally.summary(); exit(0)
    }
}

signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler { MainActor.assumeIsolated { Tally.summary() }; exit(0) }
interrupt.resume()

Task { @MainActor in
    do { try await run() } catch { say("Failed: \(error.localizedDescription)"); exit(1) }
}
RunLoop.main.run()
