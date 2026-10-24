import AVFoundation
import AssistCore
import Foundation

/// Second-opinion transcription. Apple's on-device recognizer streams words instantly, which is
/// what lets answers fire before the speaker finishes, but in a noisy room it gets a quarter of
/// the words wrong (bench: 26% word error at 5 dB babble, far field). Whisper large-v3-turbo on
/// Groq, given the names we care about, gets 5.6% on the same audio and answers in ~250 ms.
///
/// So: partial results pass straight through (fast speculation), and each finished sentence is
/// re-transcribed from the recorded audio before the engine commits it. Partials of the next
/// sentence that arrive meanwhile are queued behind it, so the engine sees events in order.
@MainActor public final class SecondPass {
    public var model = "whisper-large-v3-turbo"
    /// Give up on Whisper and use Apple's words after this long.
    public var timeout = 0.9
    public var vocabulary: [String]
    /// (original, corrected or nil, milliseconds, note) — for the event log.
    public var report: ((String, String?, Int, String) -> Void)?
    public private(set) var used = 0

    private let key: String?
    private let ring = AudioRing(seconds: 45)
    private var queue: [(String, Bool, Double?, Double?)] = []
    private var draining = false
    private var recent: [String] = []
    /// End of the previous finished sentence: never reach back into it, or Whisper hears the
    /// last words of that sentence again.
    private var lastEnd = 0.0

    public init(key: String?, vocabulary: [String]) {
        self.key = key
        self.vocabulary = vocabulary
    }

    /// Hook into a transcriber; returns the handler to pass to `run`, wrapping `deliver`.
    public func attach(_ transcriber: Transcriber, deliver: @escaping Transcriber.Handler) -> Transcriber.Handler {
        let ring = self.ring
        transcriber.onAudio = { buffer, t in ring.append(buffer, at: t) }
        // Strong self: the returned handler is what keeps this object alive for the session.
        return { [weak transcriber] text, final, end in
            self.queue.append((text, final, end, final ? transcriber?.resultStart : nil))
            if !self.draining { self.drain(deliver) }
        }
    }

    private func drain(_ deliver: @escaping Transcriber.Handler) {
        draining = true
        Task { @MainActor in
            while !queue.isEmpty {
                let (text, final, end, start) = queue.removeFirst()
                guard final else { deliver(text, false, end); continue }
                deliver(await correct(text, start: start, end: end), true, end)
            }
            draining = false
        }
    }

    private func correct(_ text: String, start: Double?, end: Double?) async -> String {
        let wordCount = text.split(separator: " ").count
        // "Okay." "Wow." — not worth a request (the free tier allows 2,000 a day).
        guard key != nil, wordCount >= 3 || text.hasSuffix("?") else { return text }
        let from = max((start ?? 0) - 0.25, lastEnd)
        if let end { lastEnd = max(lastEnd, end) }
        guard let start, let end, end > start, let wav = ring.wav(from: from, to: end + 0.2) else {
            report?(text, nil, 0, "no audio for range \(start.map { String(format: "%.2f", $0) } ?? "nil")–\(end.map { String(format: "%.2f", $0) } ?? "nil") (\(ring.span))")
            return text
        }
        let t0 = Date()
        let prompt = (vocabulary.joined(separator: ", ") + ". " + recent.suffix(2).joined(separator: " "))
        let result = await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await Self.whisper(wav, model: self.model, prompt: prompt, key: self.key!) }
            group.addTask { try? await Task.sleep(for: .seconds(self.timeout)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        guard let fixed = result?.trimmingCharacters(in: .whitespacesAndNewlines), !fixed.isEmpty else {
            report?(text, nil, ms, ms >= Int(timeout * 1000) ? "timed out" : "failed")
            remember(text)
            return text
        }
        used += 1
        // Whisper's known failure: confident filler on near-silence. Keep Apple's words when the
        // two disagree wildly in length.
        let n = fixed.split(separator: " ").count
        if Self.hallucinations.contains(fixed.lowercased()) || Double(n) < Double(wordCount) * 0.4 || Double(n) > Double(wordCount) * 2.5 + 3 {
            report?(text, nil, ms, "kept Apple's (Whisper said \"\(fixed)\")")
            remember(text)
            return text
        }
        report?(text, fixed, ms, "")
        remember(fixed)
        return fixed
    }

    private func remember(_ s: String) {
        recent.append(s)
        if recent.count > 4 { recent.removeFirst() }
    }

    static let hallucinations: Set<String> = ["thank you.", "thanks for watching!", "you", "you.", "bye.", "thank you for watching."]

    nonisolated static func whisper(_ wav: Data, model: String, prompt: String, key: String) async throws -> String {
        let boundary = UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("language", "en")
        field("temperature", "0")
        field("response_format", "json")
        field("prompt", String(prompt.prefix(600)))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"s.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("calhacks-assist/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        Quota.shared.note(response, model: model)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else { throw AnswerError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
        return text
    }
}

/// The last N seconds of recognizer audio as mono 16-bit samples, addressable by audio-clock time.
final class AudioRing: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var firstTime = 0.0
    private var rate = 16000.0
    private let seconds: Double

    init(seconds: Double) { self.seconds = seconds }

    func append(_ buffer: AVAudioPCMBuffer, at t: Double) {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var chunk = [Int16](repeating: 0, count: n)
        if let p = buffer.int16ChannelData?[0] {
            for i in 0..<n { chunk[i] = p[i] }
        } else if let p = buffer.floatChannelData?[0] {
            for i in 0..<n { chunk[i] = Int16(max(-1, min(1, p[i])) * 32767) }
        } else { return }
        lock.lock(); defer { lock.unlock() }
        rate = buffer.format.sampleRate
        if samples.isEmpty { firstTime = t }
        // Keep time alignment if a buffer was dropped.
        let expected = firstTime + Double(samples.count) / rate
        if t > expected + 0.05 { samples.append(contentsOf: [Int16](repeating: 0, count: Int((t - expected) * rate))) }
        samples.append(contentsOf: chunk)
        let excess = samples.count - Int(seconds * rate)
        if excess > Int(rate) {
            samples.removeFirst(excess)
            firstTime += Double(excess) / rate
        }
    }

    var span: String {
        lock.lock(); defer { lock.unlock() }
        return String(format: "have %.2f–%.2f s @%.0f Hz", firstTime, firstTime + Double(samples.count) / rate, rate)
    }

    func wav(from a: Double, to b: Double) -> Data? {
        lock.lock(); defer { lock.unlock() }
        let i = max(0, Int((a - firstTime) * rate)), j = min(samples.count, Int((b - firstTime) * rate))
        guard j - i > Int(rate * 0.3) else { return nil }
        let pcm = samples[i..<j]
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(Data("RIFF".utf8)); u32(UInt32(36 + pcm.count * 2)); d.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(UInt32(pcm.count * 2))
        pcm.withUnsafeBufferPointer { d.append(UnsafeBufferPointer(start: UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: UInt8.self), count: $0.count * 2)) }
        return d
    }
}
