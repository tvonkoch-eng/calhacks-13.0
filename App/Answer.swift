import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where answers come from. All four are OpenAI-compatible, so one code path covers them;
/// pick whichever key you have. Groq and Cerebras are the fastest — their time-to-first-token is
/// ~100-250 ms, which is the whole ballgame on a wearable. Muse is Meta's Muse Spark: always
/// reasons first, so ~1.2 s to first token (see Tests/muse-latency.py).
enum Provider: String {
    case groq, cerebras, openai, muse

    var endpoint: URL {
        switch self {
        case .groq: URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        case .cerebras: URL(string: "https://api.cerebras.ai/v1/chat/completions")!
        case .openai: URL(string: "https://api.openai.com/v1/chat/completions")!
        case .muse: URL(string: "https://api.meta.ai/v1/chat/completions")!
        }
    }

    /// Measured against this exact system prompt on 2026-10-23 (see Tests/groq-latency.md):
    /// qwen3.8-27b answers in ~100 ms to first token and got 20/20 of our answer-vs-SKIP cases.
    /// Do NOT swap in Groq's gpt-oss models — they are reasoning models, so they spend the whole
    /// token budget on hidden reasoning before emitting any content, which both doubles the
    /// latency and, at a small max_tokens, returns an empty answer that looks like a SKIP.
    var model: String {
        switch self {
        case .groq: "qwen/qwen3.8-27b"
        // gpt-oss-120b: OpenAI's open-weight model; Cerebras serves it fastest of any host.
        case .cerebras: "gpt-oss-120b"
        // gpt-4.1-mini: 20/20 answer-vs-SKIP, median first token 0.66 s (2026-10-23). gpt-4o-mini
        // and gpt-5.4-mini answered "did you see the keynote"; gpt-5.4-nano failed 6 of 20.
        case .openai: "gpt-4.1-mini"
        // 1.1 over 1.3: both 20/20 on answer-vs-SKIP, 1.1 median first token 1.17 s vs 1.87 s
        // (2026-10-23, Tests/muse-latency.py). Override with ANSWER_MODEL.
        case .muse: "muse-spark-1.1"
        }
    }

    /// Reasoning models think before they answer: at 48 tokens they spend the whole budget
    /// thinking and return no content. Low effort plus room to think fixes it.
    func extras(model: String) -> [String: Any] {
        if model.contains("gpt-oss") { return ["max_tokens": 600, "reasoning_effort": "low"] }
        // Cerebras runs Qwen3 with thinking on by default; "none" turns it off (3 tokens, not 30).
        if self == .cerebras, model.contains("qwen") { return ["max_tokens": 48, "reasoning_effort": "none"] }
        switch self {
        case .muse: return ["max_tokens": 400, "reasoning_effort": "minimal"]
        default: return ["max_tokens": 48]
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

    static var model: String {
        let name = Bundle.main.object(forInfoDictionaryKey: "AnswerModel") as? String
        return (name?.isEmpty == false) ? name! : provider.model
    }

    static var configured: Bool { key != nil }

    private static let prompt = """
    You help someone wearing smart glasses during a live, in-person conversation. The input is a \
    live speech transcript of a question someone just asked out loud, sometimes after what's known \
    about the other person and the last few lines of the conversation. The question may be cut off \
    mid-sentence — infer the obvious full question and answer that. The audio is often imperfect, \
    so read through misheard or missing words to what was clearly meant. Speech recognition mishears \
    jargon: read "the sharp on a market making book" as the Sharpe ratio, and so on, when the \
    conversation makes the meaning clear.

    Answer in ONE line of at most 12 words. No preamble, no restating the question, no punctuation \
    at the end. If the answer is a number or a name, lead with it. Plain facts only. If the \
    conversation or what's known about them answers it, answer from that.

    Reply with exactly WEB, and nothing else, if it is a public fact you can't give reliably from \
    memory: news or anything recent, prices, scores, schedules, or a specific company, product or \
    paper you don't know well. You do know the current date and time (below): use them for time \
    zones, ages and countdowns.

    Reply with exactly SKIP, and nothing else, if the question is personal or social (about the \
    people talking, their feelings, plans, opinions or preferences, or anything that's theirs: \
    their company, project, school, family) and nothing above answers it; or if it is rhetorical, \
    a request to do something, or too fragmentary to guess at. Never guess about the people \
    talking, and never send them to the web.
    """

    /// "I don't have real-time…", "Sorry, …": a refusal on the lens is worse than nothing, so it is
    /// treated as a SKIP. Facts never start in the first person.
    static func refuses(_ text: String) -> Bool {
        let t = text.trimmed.uppercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return ["I ", "I'", "SORRY", "AS AN AI", "UNFORTUNATELY"].contains { t.hasPrefix($0) }
    }

    /// Instant, no network. Covers the questions that are embarrassing to be slow on.
    static func local(_ question: String) -> String? {
        let q = question.lowercased()
        // "what time is it in Tokyo" is not the local time: that goes to a model that knows the zone.
        if q.contains("what time"), q.contains("it"), !q.contains(" in "), !q.contains(" there") {
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
    /// Yields nothing at all when the model says SKIP; throws `AnswerError.lookup` when it says the
    /// answer needs the web.
    /// `context` is the last few lines of the conversation, so "when did it come out" can resolve
    /// "it". `provider`, `key` and `model` default to the app's configuration.
    static func stream(_ question: String, context: String = "", provider: Provider = provider,
                       key: String? = key, model: String = model) -> AsyncThrowingStream<String, Error> {
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
                    var body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "temperature": 0,
                        "messages": [
                            // Without the date, "how many days until Thanksgiving" is a guess.
                            ["role": "system", "content": prompt + "\nIt is "
                                + Date().formatted(.dateTime.weekday(.wide).month(.wide).day().year().hour().minute())
                                + " " + (TimeZone.current.abbreviation() ?? TimeZone.current.identifier) + "."],
                            ["role": "user", "content": context.isEmpty
                                ? question : "Conversation so far:\n\(context)\n\nQuestion: \(question)"],
                        ],
                    ]
                    body.merge(provider.extras(model: model)) { _, extra in extra }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

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
                        // Bail the instant the model starts refusing; nothing reaches the lens. Some
                        // models stream "SKIP" as "SK" + "IP", so hold back anything that could still
                        // turn into it, or into WEB.
                        let head = answer.trimmed.uppercased()
                        if head.hasPrefix("SKIP") || Answerer.refuses(head) {
                            continuation.finish()
                            return
                        }
                        // "WEB", "WEB." or "WEB: …" is the sentinel; "Webb telescope" is an answer.
                        if head.hasPrefix("WEB"), !(head.dropFirst(3).first?.isLetter ?? false) {
                            if head.count > 3 {
                                continuation.finish(throwing: AnswerError.lookup)
                                return
                            }
                            continue
                        }
                        if "SKIP".hasPrefix(head) || "WEB".hasPrefix(head) || head == "I" || head == "AS" { continue }
                        continuation.yield(answer.trimmed)
                    }
                    if answer.trimmed.uppercased() == "WEB" {
                        continuation.finish(throwing: AnswerError.lookup)
                        return
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
    /// A public fact the model can't give from memory: look it up (Aid.lookUp).
    case lookup

    var errorDescription: String? {
        switch self {
        case .unconfigured: "No answer API key — add one to Secrets.xcconfig"
        case .http(let code): "Answer service returned \(code)"
        case .lookup: "Needs a lookup"
        }
    }
}
