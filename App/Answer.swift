import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where answers come from. All three are OpenAI-compatible, so one code path covers them;
/// pick whichever key you have. Groq and Cerebras are the ones worth using here — their
/// time-to-first-token is ~100-250 ms, which is the whole ballgame on a wearable.
enum Provider: String {
    case groq, cerebras, openai

    var endpoint: URL {
        switch self {
        case .groq: URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        case .cerebras: URL(string: "https://api.cerebras.ai/v1/chat/completions")!
        case .openai: URL(string: "https://api.openai.com/v1/chat/completions")!
        }
    }

    var model: String {
        switch self {
        case .groq: "llama-3.3-70b-versatile"
        case .cerebras: "llama-3.3-70b"
        case .openai: "gpt-4o-mini"
        }
    }
}

/// Answers questions in one short line, fast. Two tiers:
/// - A local tier for arithmetic, time and date, which lands on the lens in under a millisecond.
/// - A streaming model call for everything else, surfaced token by token so the first words show
///   up long before the sentence is done.
struct Answerer {
    /// Set `ANSWER_API_KEY` / `ANSWER_PROVIDER` in Secrets.xcconfig (see Secrets.example.xcconfig).
    static var key: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "AnswerAPIKey") as? String
        return (value?.isEmpty == false) ? value : nil
    }

    static var provider: Provider {
        let name = Bundle.main.object(forInfoDictionaryKey: "AnswerProvider") as? String
        return Provider(rawValue: name?.lowercased() ?? "") ?? .groq
    }

    static var configured: Bool { key != nil }

    private static let prompt = """
    You help someone wearing smart glasses during a live, in-person conversation. The input is a \
    live speech transcript of a question someone just asked out loud. It may be cut off mid-sentence \
    — infer the obvious full question and answer that.

    Answer in ONE line of at most 12 words. No preamble, no restating the question, no punctuation \
    at the end. If the answer is a number or a name, lead with it. Plain facts only.

    Reply with exactly SKIP, and nothing else, if the question is personal or social (about the \
    people talking, their feelings, plans, opinions or preferences), rhetorical, a request to do \
    something, or too fragmentary to guess at.
    """

    /// Instant, no network. Covers the questions that are embarrassing to be slow on.
    static func local(_ question: String) -> String? {
        let q = question.lowercased()
        if q.contains("what time"), q.contains("it") {
            return Date().formatted(date: .omitted, time: .shortened)
        }
        if q.contains("what") , q.contains("date") || q.contains("day is") {
            return Date().formatted(date: .abbreviated, time: .omitted)
        }
        return arithmetic(q)
    }

    /// "whats 17 times 23" → "391". Spoken operators only; digits come through the recognizer.
    private static func arithmetic(_ q: String) -> String? {
        let ops: [(String, (Double, Double) -> Double)] = [
            ("times", *), ("multiplied by", *), ("x", *),
            ("divided by", /), ("over", /),
            ("plus", +), ("minus", -),
        ]
        for (word, apply) in ops {
            let parts = q.components(separatedBy: " \(word) ")
            guard parts.count == 2,
                  let a = number(in: parts[0], fromEnd: true),
                  let b = number(in: parts[1], fromEnd: false) else { continue }
            let result = apply(a, b)
            guard result.isFinite else { return nil }
            return result == result.rounded()
                ? String(Int(result))
                : String(format: "%.2f", result)
        }
        return nil
    }

    private static func number(in text: String, fromEnd: Bool) -> Double? {
        let tokens = text.components(separatedBy: CharacterSet(charactersIn: " ,"))
            .compactMap { Double($0.filter { $0.isNumber || $0 == "." || $0 == "-" }) }
        return fromEnd ? tokens.last : tokens.first
    }

    /// Streams the answer. Yields a growing string; the last value is the whole answer.
    /// Yields nothing at all when the model says SKIP.
    static func stream(_ question: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task.detached {
                do {
                    guard let key else {
                        throw AnswerError.unconfigured
                    }
                    var request = URLRequest(url: provider.endpoint)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 8
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": provider.model,
                        "stream": true,
                        "temperature": 0,
                        "max_tokens": 48,
                        "messages": [
                            ["role": "system", "content": prompt],
                            ["role": "user", "content": question],
                        ],
                    ])

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw AnswerError.http(http.statusCode)
                    }

                    var answer = ""
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let chunk = delta["content"] as? String, !chunk.isEmpty else { continue }
                        answer += chunk
                        // Bail the instant the model starts refusing; nothing reaches the lens.
                        if answer.trimmed.uppercased().hasPrefix("SKIP") {
                            continuation.finish()
                            return
                        }
                        continuation.yield(answer.trimmed)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}

enum AnswerError: LocalizedError {
    case unconfigured
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .unconfigured: "No answer API key — add one to Secrets.xcconfig"
        case .http(let code): "Answer service returned \(code)"
        }
    }
}
