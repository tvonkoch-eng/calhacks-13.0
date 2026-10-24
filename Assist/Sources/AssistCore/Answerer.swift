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
    /// `settled` means the speaker has finished: the question will not grow, so the model must
    /// answer or SKIP, never WAIT.
    func stream(_ question: String, context: String, settled: Bool) -> AsyncThrowingStream<AnswerEvent, Error>
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

    /// Used when the main Groq model returns 429 (daily request cap): separate quota.
    public static let groqFallback = "openai/gpt-oss-20b"

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

    /// Shared rules. The speculative (unsettled) and final (settled) requests differ only in the
    /// suffix: a partial may be refused with WAIT, a finished sentence may not.
    public static let prompt = """
    You help someone wearing smart glasses during a live, in-person conversation. The input is a \
    live speech transcript of a question someone is asking out loud.

    Answer in ONE line of at most 12 words. No preamble, do not restate the question, no trailing \
    punctuation. If the answer is a number or a name, lead with it. Plain facts only.

    Reply with exactly SKIP if the question is about the people talking (their lives, feelings, \
    plans, opinions or preferences), is rhetorical, or asks someone to do something.

    "Said just before" is earlier conversation. Words like it, there, she or he mean the most \
    recent matching thing there; resolve them and answer.
    """

    /// Speculative request: the sentence is still being spoken, so refusing a fragment is useful.
    public static let partialSuffix = """

    The speaker may still be talking, so the last word can be cut off mid-word ("eiff" for \\
    Eiffel, "jup" for Jupiter): complete it and answer. If the full question is clear from what \\
    is there, answer it.
    Reply with exactly WAIT only if the thing being asked about has not been said yet, like \\
    "how tall is the", "who wrote" or "what is the capital".
    """

    /// Final request: no more words are coming, so there is nothing to wait for. WAIT is not
    /// offered at all here — mentioning it at all made the model stall on complete questions
    /// whose answer depends on context it does not have.
    public static let settledSuffix = """

    The speaker has finished, so this is the whole question. Always give a short answer or SKIP. \
    For quantities (distances, sizes, counts, dates) give your best estimate if unsure, leading \
    with "about". For a specific fact you do not know (who won a small event, a niche detail), \
    reply SKIP rather than guess. \
    Never ask for more information.
    """

    // MARK: - Local tier

    public func local(_ question: String) -> String? { Self.local(question) }

    /// Instant, no network. Covers the questions that are embarrassing to be slow on.
    public static func local(_ question: String) -> String? {
        let q = question.lowercased()
        // Only the clock/calendar question itself. "what time does it start" and "what date did
        // the wall fall" are about something else and go to the model.
        let plain = QuestionGate.plain(question)
        if plain.wholeMatch(of: timeAsk) != nil {
            return Date().formatted(date: .omitted, time: .shortened)
        }
        if plain.wholeMatch(of: dateAsk) != nil {
            return Date().formatted(date: .abbreviated, time: .omitted)
        }
        return arithmetic(q)
    }

    nonisolated(unsafe) private static let timeAsk = try! Regex(
        #"(?:(?:so|and|ok|okay|hey|um|uh) )*(?:what time is it|what time it is|whats the time|what is the time|whats the current time|what is the current time)(?: now| right now| here)?"#)
    nonisolated(unsafe) private static let dateAsk = try! Regex(
        #"(?:(?:so|and|ok|okay|hey|um|uh) )*(?:(?:whats|what is) (?:the date|todays date|the date today)(?: today)?|what day is (?:it|today)(?: today)?|what day it is|whats today|what is today)"#)

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

    public func stream(_ question: String, context: String, settled: Bool) -> AsyncThrowingStream<AnswerEvent, Error> {
        let content = context.isEmpty ? question : "Said just before: \(context)\nQuestion: \(question)"
        let system = Self.prompt + (settled ? Self.settledSuffix : Self.partialSuffix)
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
                    func body(_ model: String) throws -> Data {
                        var b: [String: Any] = [
                            "model": model,
                            "stream": true,
                            "temperature": 0,
                            "max_tokens": 48,
                            "messages": [
                                ["role": "system", "content": system],
                                ["role": "user", "content": content],
                            ],
                        ]
                        // gpt-oss reasons before answering: keep that short and out of the stream.
                        if model.hasPrefix("openai/gpt-oss") {
                            b["reasoning_effort"] = "low"; b["include_reasoning"] = false; b["max_tokens"] = 400
                        }
                        return try JSONSerialization.data(withJSONObject: b)
                    }
                    request.httpBody = try body(provider.model)
                    var (bytes, response) = try await URLSession.shared.bytes(for: request)
                    Quota.shared.note(response, model: provider.model)
                    // Free-tier daily cap (or a burst limit) on the main model: answer with the
                    // fallback model, which has its own separate quota, rather than show nothing.
                    if let http = response as? HTTPURLResponse, http.statusCode == 429, provider == .groq {
                        request.httpBody = try body(Provider.groqFallback)
                        (bytes, response) = try await URLSession.shared.bytes(for: request)
                        Quota.shared.note(response, model: Provider.groqFallback)
                    }
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
                        if head.hasPrefix("SKIP") || head.hasPrefix("I DON'T KNOW") || head.hasPrefix("I DON\u{2019}T KNOW") || head.hasPrefix("UNKNOWN") {
                            continuation.yield(.personal); continuation.finish(); return
                        }
                        // Could still become "I don't know": hold it back until it can't.
                        if "I DON'T KNOW".hasPrefix(head) || "UNKNOWN".hasPrefix(head) { continue }
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
