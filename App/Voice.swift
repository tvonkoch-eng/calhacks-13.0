import AVFoundation
import Foundation

/// Jarvis's voice: Cartesia Sonic, out of the glasses' speakers (Bluetooth A2DP), and only for
/// answers to "Jarvis, …"; the conversation aid stays silent on the lens. While it talks the mic
/// sends silence (`onSpeaking`), so neither Muse nor the glasses' own transcription hears it.
@MainActor final class Voice: NSObject, AVAudioPlayerDelegate {
    /// CARTESIA_API_KEY in Secrets.xcconfig. No key, no voice: answers stay on the lens only.
    nonisolated static let key = setting("CartesiaAPIKey")
    /// CARTESIA_VOICE: any voice id from play.cartesia.ai. Unset: a calm stock voice.
    nonisolated static let voiceID = setting("CartesiaVoice") ?? "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4"
    nonisolated static let model = setting("CartesiaModel") ?? "sonic-3.6"

    private(set) var speaking = false
    /// How long it is about to talk, then nil when it's done (or cut off): the host mutes the mic.
    var onSpeaking: ((TimeInterval?) -> Void)?
    var onLog: (([String: Any]) -> Void)?

    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?

    var available: Bool { Self.key != nil }

    /// Says `text`, cutting off whatever it was saying.
    func speak(_ text: String) {
        guard let key = Self.key, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        stop()
        let started = Date()
        task = Task { [weak self] in
            do {
                let audio = try await Self.synthesize(text, key: key)
                guard !Task.isCancelled, let self else { return }
                let player = try AVAudioPlayer(data: audio)
                player.delegate = self
                self.player = player
                self.speaking = true
                self.onSpeaking?(player.duration)
                player.play()
                self.onLog?(["event": "voice", "ms": Int(Date().timeIntervalSince(started) * 1000),
                             "seconds": (player.duration * 10).rounded() / 10, "chars": text.count])
            } catch {
                guard !Task.isCancelled else { return }
                self?.onLog?(["event": "voiceError", "error": error.localizedDescription])
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if speaking {
            player?.stop()
            speaking = false
            onSpeaking?(nil)
        }
        player = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.speaking = false
            self.player = nil
            self.onSpeaking?(nil)
        }
    }

    /// One request, the whole clip back as WAV. Answers are a sentence, so streaming would save
    /// little; the bytes endpoint keeps it to one round trip.
    nonisolated static func synthesize(_ text: String, key: String, voice: String = voiceID, model: String = model) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.cartesia.ai/tts/bytes")!, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("2026-08-14", forHTTPHeaderField: "Cartesia-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model_id": model,
            "transcript": spoken(text),
            "voice": ["id": voice],
            "output_format": ["container": "wav", "encoding": "pcm_s16le", "sample_rate": 24000],
            "language": "en",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, !data.isEmpty else {
            throw NSError(domain: "Cartesia", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "Cartesia \(status): \(String(decoding: data.prefix(200), as: UTF8.self))"])
        }
        return data
    }

    /// Lens text read aloud: "61°F, clear · high 73°" → "61°F, clear. high 73°". Dashes and dots
    /// that separate on the lens are pauses out loud.
    nonisolated static func spoken(_ text: String) -> String {
        text.replacingOccurrences(of: " \u{00B7} ", with: ". ")
            .replacingOccurrences(of: " \u{2014} ", with: ", ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func setting(_ key: String) -> String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }
}
