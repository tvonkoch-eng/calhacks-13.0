import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the answer model said, as it streams.
public enum AnswerEvent: Sendable, Equatable {
    /// The answer so far (grows; the last one is the whole answer).
    case text(String)
    /// About the people talking, rhetorical, or a request. Never shown.
    case personal
    /// Cut off too early to tell what is being asked. Worth asking again once more words arrive.
    case incomplete
}

/// Anything that can answer a question. The engine only sees this, so tests can fake it.
public protocol AnswerSource: Sendable {
    /// Instant, on-device answers (arithmetic, time, date), or nil.
    func local(_ question: String) -> String?
    /// `context`: the last few sentences of conversation, to resolve "it", "she", "that one".
    func stream(_ question: String, context: String) -> AsyncThrowingStream<AnswerEvent, Error>
}

/// OpenAI-compatible chat endpoints. Groq is the one to use: ~100 ms to first token.
public enum Provider: String, Sendable {
    case groq, cerebras, openai

    var endpoint: URL {
        switch self {
        case .groq: URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        case .cerebras: URL(string: "https://api.cerebras.ai/v1/chat/completions")!
        case .openai: URL(string: "https://api.openai.com/v1/chat/completions")!
        }
    }

    /// Groq: qwen3.8-27b measured ~100 ms to first token, 20/20 on answer-vs-SKIP (Tests/groq-latency.md).
    /// Not Groq's gpt-oss models: they reason before answering, which is slower and can return nothing.
    public var model: String {
        switch self {
        case .groq: "qwen/qwen3.8-27b"
        case .cerebras: "llama-3.3-70b"
        case .openai: "gpt-4o-mini"
        }
    }
}

public struct Answerer: AnswerSource {
    public let key: String?
    public let provider: Provider

    public init(key: String?, provider: Provider = .groq) {
        self.key = (key?.isEmpty == false) ? key : nil
        self.provider = provider
    }

    /// iPhone app: the key arrives through Secrets.xcconfig → Info.plist.
    public static func fromBundle() -> Answerer {
        let info = Bundle.main.infoDictionary ?? [:]
        let provider = (info["AnswerProvider"] as? String).flatMap { Provider(rawValue: $0.lowercased()) } ?? .groq
        return Answerer(key: info["AnswerAPIKey"] as? String, provider: provider)
    }

    /// Mac tool: $ANSWER_API_KEY / $GROQ_API_KEY, else the first Secrets.xcconfig found in `directories`.
    public static func fromEnvironment(searching directories: [URL]) -> Answerer {
        let env = ProcessInfo.processInfo.environment
        let provider = env["ANSWER_PROVIDER"].flatMap { Provider(rawValue: $0.lowercased()) }
        if let key = env["ANSWER_API_KEY"] ?? env["GROQ_API_KEY"], !key.isEmpty {
            return Answerer(key: key, provider: provider ?? .groq)
        }
        for dir in directories {
            guard let text = try? String(contentsOf: dir.appendingPathComponent("Secrets.xcconfig"), encoding: .utf8)
            else { continue }
            var values: [String: String] = [:]
            for line in text.split(separator: "\n") where !line.hasPrefix("//") {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { values[parts[0]] = parts[1] }
            }
            if let key = values["ANSWER_API_KEY"], !key.isEmpty {
                return Answerer(key: key, provider: provider ?? values["ANSWER_PROVIDER"].flatMap { Provider(rawValue: $0) } ?? .groq)
            }
        }
        return Answerer(key: nil, provider: provider ?? .groq)
    }

    public static let prompt = """
    You help someone wearing smart glasses during a live, in-person conversation. The input is a \
    live speech transcript of a question someone is asking out loud, possibly cut off \
    mid-sentence. If the full question is clear from what is there, answer it.

    Answer in ONE line of at most 12 words. No preamble, do not restate the question, no trailing \
    punctuation. If the answer is a number or a name, lead with it. Plain facts only.

    Reply with exactly SKIP if the question is about the people talking (their lives, feelings, \
    plans, opinions or preferences), is rhetorical, or asks someone to do something.
    Reply with exactly WAIT if it is cut off too early to tell what is being asked.

    "Said just before" is earlier conversation, only for resolving words like it, she or there.
    """

    // MARK: - Local tier

    public func local(_ question: String) -> String? { Self.local(question) }

    /// Instant, no network. Covers the questions that are embarrassing to be slow on.
    public static func local(_ question: String) -> String? {
        let q = question.lowercased()
        if q.contains("what time"), q.contains(" it") {
            return Date().formatted(date: .omitted, time: .shortened)
        }
        if q.contains("what"), q.contains("date") || q.contains("day is") {
            return Date().formatted(date: .abbreviated, time: .omitted)
        }
        return arithmetic(q)
    }

    /// "whats 17 times 23" → "391". Recognizers write numbers as digits.
    private static func arithmetic(_ q: String) -> String? {
        let ops: [(String, (Double, Double) -> Double)] = [
            ("times", *), ("multiplied by", *), ("x", *), ("×", *), ("*", *),
            ("divided by", /), ("over", /), ("÷", /), ("/", /),
            ("plus", +), ("+", +), ("minus", -),
        ]
        for (word, apply) in ops {
            let parts = q.components(separatedBy: " \(word) ")
            guard parts.count == 2,
                  let a = number(in: parts[0], fromEnd: true),
                  let b = number(in: parts[1], fromEnd: false) else { continue }
            let result = apply(a, b)
            guard result.isFinite else { return nil }
            return result == result.rounded() ? String(Int(result)) : String(format: "%.2f", result)
        }
        return nil
    }

    private static func number(in text: String, fromEnd: Bool) -> Double? {
        let tokens = text.components(separatedBy: CharacterSet(charactersIn: " ,?"))
            .compactMap { token -> Double? in
                let digits = token.filter { $0.isNumber || $0 == "." || $0 == "-" }
                return digits.isEmpty ? nil : Double(digits)
            }
        return fromEnd ? tokens.last : tokens.first
    }

    // MARK: - Model tier

    public func stream(_ question: String, context: String) -> AsyncThrowingStream<AnswerEvent, Error> {
        let content = context.isEmpty ? question : "Said just before: \(context)\nQuestion: \(question)"
        let key = key, provider = provider
        return AsyncThrowingStream { continuation in
            let work = Task.detached {
                do {
                    guard let key else { throw AnswerError.unconfigured }
                    var request = URLRequest(url: provider.endpoint)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 8
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("calhacks-assist/1.0", forHTTPHeaderField: "User-Agent")
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": provider.model,
                        "stream": true,
                        "temperature": 0,
                        "max_tokens": 48,
                        "messages": [
                            ["role": "system", "content": Self.prompt],
                            ["role": "user", "content": content],
                        ],
                    ] as [String: Any])

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw AnswerError.http(http.statusCode)
                    }
                    var answer = ""
                    var shown = false
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
                        let head = answer.trimmed.uppercased()
                        if head.hasPrefix("SKIP") { continuation.yield(.personal); continuation.finish(); return }
                        if head.hasPrefix("WAIT") { continuation.yield(.incomplete); continuation.finish(); return }
                        // "S" or "WA" could still turn into a control word; never flash it on the lens.
                        if "SKIP".hasPrefix(head) || "WAIT".hasPrefix(head) { continue }
                        shown = true
                        continuation.yield(.text(answer.trimmed))
                    }
                    if !shown {
                        let rest = answer.trimmed
                        continuation.yield(rest.isEmpty ? .incomplete : .text(rest))
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

public enum AnswerError: LocalizedError {
    case unconfigured
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .unconfigured: "No answer API key (ANSWER_API_KEY in Secrets.xcconfig)"
        case .http(let code): "Answer service returned HTTP \(code)"
        }
    }
}
