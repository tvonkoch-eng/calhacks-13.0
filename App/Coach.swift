import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The slow lane. After each of the other person's turns, one call decides what the wearer should
/// see beyond answers: a term to define, the best thing to say next, who they're talking to, and
/// whether anything deserves a deeper look. Answers to questions stay in the fast lane (Answer.swift)
/// because they are useless late; this lane can take half a second.
enum Coach {
    /// What the coach sees on each call.
    struct Input {
        var wearer: String
        /// What the wearer already knows, so obvious terms aren't defined ("CS student, knows ML").
        var background = ""
        var known: String          // "Priya · Berkeley CS student; paralegal for two years"
        var defined: [String]
        var researched: [String]
        var suggestion: String?
        var transcript: [String]   // "THEM: …", oldest first; the last one is new
    }

    enum Followup: Equatable { case keep, clear, say(String) }

    struct Advice: Equatable {
        var define: [(term: String, meaning: String)] = []
        var followup: Followup = .keep
        var name: String?
        var label: String?
        var facts: [String] = []
        var research: String?

        static func == (a: Advice, b: Advice) -> Bool {
            a.define.map { "\($0.term)=\($0.meaning)" } == b.define.map { "\($0.term)=\($0.meaning)" }
                && a.followup == b.followup && a.name == b.name && a.label == b.label
                && a.facts == b.facts && a.research == b.research
        }
    }

    // Tuned on three scripted conversations (hackathon, investor, catch-up) on 2026-10-23. What
    // moved quality most: per-field restraint instead of a global "say less" (that suppressed every
    // definition), "THEM volunteered" + motives over logistics for follow-ups, and telling it that
    // questions are answered elsewhere (it was researching them).
    static let prompt = """
    You are a conversation coach inside AR glasses. The wearer is in a live, in-person conversation \
    with one other person and glances at a tiny display while they talk. After each new line of the \
    transcript you decide what belongs on that display.

    Lines are tagged ME (the wearer) and THEM (the other person), or A and B while it is not yet \
    known which speaker is the wearer; then suggest what either could usefully say. The transcript comes from live speech recognition, so expect \
    misheard words and the odd wrong tag. Questions asked out loud are answered by a separate system: \
    never define, research or suggest a follow-up just to answer one.

    Reply with one JSON object with exactly these keys:

    "define": [{"term": "...", "meaning": "..."}]
      Up to 2, only for terms in the newest line that an educated non-specialist may not know: \
    jargon, an acronym, a technical method, a niche product, company, person, place, or a foreign \
    phrase. "meaning" is at most 8 plain words and does not repeat the term. Skip everyday words, \
    anything the wearer's background already covers, anything in "Already defined", and what looks \
    like a recognition error. Least familiar first. Usually [].

    "followup": "..." or "" or null
      The single best thing for the wearer to say next, usually a question, at most 12 words, in the \
    wearer's own voice, with no greeting and no name.
      Great follow-ups pick up a specific detail THEM volunteered, especially one they didn't have to \
    mention, and ask about motives, experiences or feelings (why, how, what was it like) rather than \
    logistics. Open-ended, curious, warm; never an interview, never prying, never something already \
    asked or answered.
      null keeps "Current suggestion" on screen. Keep it while it still fits. Replace it when THEM's \
    newest line answers it, when ME just asked it or something close, when the conversation has \
    moved on, or when you have a clearly better one. "" clears it.
      After a silence, revive an earlier thread THEM mentioned that nobody followed up on.

    "them": {"name": "...", "label": "..."} or null
      Only what is new or changed. name: the other person's first name, once they say it. label: at \
    most 4 words on who they are (role, company or school).

    "facts": ["..."]
      Facts THEM just revealed about themselves (work, school, hometown, plans, family, interests) \
    that are not already in "Known about them", each at most 8 words. Often [].

    "research": "..." or null
      A web search query when THEM names something specific the wearer would benefit from knowing \
    more about right now: their company or project, a product, a paper, a person, or a factual claim \
    worth checking. Include enough context words to find the right thing despite misheard names \
    (for example "Relit AI ERP startup Series A"). At most once per topic; never repeat "Already \
    researched"; null for small talk.
    """

    static func message(_ input: Input) -> String {
        func list(_ items: [String]) -> String { items.isEmpty ? "none" : items.joined(separator: ", ") }
        let suggestion = input.suggestion.map { "\"\($0)\"" } ?? "none"
        return """
        Wearer: \(input.wearer)\(input.background.isEmpty ? "" : " (\(input.background)); never define what they would know")
        Known about them: \(input.known.isEmpty ? "nothing yet" : input.known)
        Already defined: \(list(input.defined))
        Already researched: \(list(input.researched))
        Current suggestion: \(suggestion)

        Transcript (oldest first; the last line is new):
        \(input.transcript.joined(separator: "\n"))
        """
    }

    static func ask(_ input: Input, provider: Provider, key: String, model: String) async throws -> Advice {
        var body: [String: Any] = [
            "model": model,
            "temperature": 0.3,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": message(input)],
            ],
        ]
        // JSON is short; Muse Spark reasons before it writes any, so it needs room to think.
        body.merge(provider == .muse ? ["max_tokens": 900, "reasoning_effort": "minimal"] : ["max_tokens": 220]) { _, new in new }
        let text = try await LLM.complete(provider.endpoint, key: key, body: body, timeout: 10)
        guard let result = parse(text) else { throw LLM.Failure.unreadable(String(text.prefix(120))) }
        return result
    }

    /// Lenient on purpose: models wrap JSON in prose, return one definition as an object instead of
    /// a list, or send null where we asked for []. Anything unusable is simply absent.
    static func parse(_ text: String) -> Advice? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
        else { return nil }

        func clean(_ value: Any?) -> String? {
            guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
                  s.lowercased() != "null" else { return nil }
            return s
        }

        var result = Advice()
        let terms = (object["define"] as? [[String: Any]]) ?? ((object["define"] as? [String: Any]).map { [$0] } ?? [])
        result.define = terms.prefix(2).compactMap { entry in
            guard let term = clean(entry["term"]), let meaning = clean(entry["meaning"]) else { return nil }
            return (term, meaning)
        }
        if let followup = object["followup"] as? String {
            let text = followup.trimmingCharacters(in: .whitespacesAndNewlines)
            result.followup = text.isEmpty ? .clear : .say(text)
        }
        if let them = object["them"] as? [String: Any] {
            result.name = clean(them["name"])
            result.label = clean(them["label"])
        }
        result.facts = ((object["facts"] as? [Any]) ?? []).compactMap(clean)
        result.research = clean(object["research"])
        return result
    }
}

// MARK: - Research

/// The deeper lane: turn a query into one glanceable line, taking seconds rather than milliseconds.
/// Anything can sit behind this — a web-search model, a Fetch.ai agent on Agentverse, a company
/// database. The coach decides *what* is worth looking up; this decides how.
protocol Researcher: Sendable {
    var name: String { get }
    func research(_ query: String, context: String) async throws -> String
}

/// Any OpenAI-compatible endpoint with web search built in. Three ready-made ones:
/// - `groq`: gpt-oss-120b with Groq's browser_search tool (~3 s, but ~20k tokens a lookup, which
///   is a tenth of Groq's free daily budget).
/// - `openai`: gpt-5-search-api (~7 s, ~17k tokens; found the current GENIUS Act rulemaking).
/// - `asi1`: Fetch.ai's ASI:One (api.asi1.ai), whose `web_search` flag does the same.
/// Search models ignore length limits, so the aid condenses long findings (`Coach.condense`).
struct WebResearcher: Researcher {
    let name: String
    let endpoint: URL
    let key: String
    let model: String
    /// Provider-specific request fields, as JSON text so the struct stays Sendable.
    let extra: String

    static func groq(key: String) -> WebResearcher {
        WebResearcher(name: "Groq web search", endpoint: Provider.groq.endpoint, key: key,
                      model: "openai/gpt-oss-120b",
                      extra: #"{"tools":[{"type":"browser_search"}],"reasoning_effort":"low","max_tokens":2000}"#)
    }

    static func openai(key: String) -> WebResearcher {
        WebResearcher(name: "OpenAI web search", endpoint: Provider.openai.endpoint, key: key,
                      model: "gpt-5-search-api", extra: #"{"web_search_options":{}}"#)
    }

    static func asi1(key: String, model: String = "asi1-mini") -> WebResearcher {
        WebResearcher(name: "Fetch.ai ASI:One", endpoint: URL(string: "https://api.asi1.ai/v1/chat/completions")!,
                      key: key, model: model, extra: #"{"web_search":true}"#)
    }

    func research(_ query: String, context: String) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": """
                    You look things up for someone mid-conversation who will glance at your reply on \
                    smart glasses. Reply with the single most useful thing to know, at most 18 words, \
                    plain text, no citations, no preamble.
                    """],
                ["role": "user", "content": "Look up: \(query)\n\nConversation so far:\n\(context)"],
            ],
        ]
        if let fields = try? JSONSerialization.jsonObject(with: Data(extra.utf8)) as? [String: Any] {
            body.merge(fields) { _, new in new }
        }
        let text = try await LLM.complete(endpoint, key: key, body: body, timeout: 25)
        // Strip search citations (【1†L11-L13】) and markdown emphasis.
        let plain = text.replacingOccurrences(of: #"【[^】]*】"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { throw LLM.Failure.unreadable("empty research reply") }
        return plain
    }
}

extension Coach {
    /// A research finding cut to one glanceable line. Search models write paragraphs with links.
    static func condense(_ finding: String, query: String, provider: Provider, key: String, model: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": 60,
            "messages": [
                ["role": "system", "content": """
                    Condense research notes for someone glancing at smart glasses mid-conversation. \
                    Reply with the single most useful fact for the topic, at most 18 words, plain \
                    text: no links, no citations, no preamble.
                    """],
                ["role": "user", "content": "Topic: \(query)\n\nNotes:\n\(finding.prefix(4000))"],
            ],
        ]
        return try await LLM.complete(provider.endpoint, key: key, body: body, timeout: 8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - One non-streaming chat call

enum LLM {
    enum Failure: LocalizedError {
        case rateLimited(retryAfter: TimeInterval)
        case http(Int, String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .rateLimited(let wait): "rate limited, retrying in \(Int(wait.rounded())) s"
            case .http(let code, let body): "HTTP \(code): \(body)"
            case .unreadable(let text): "unreadable reply: \(text)"
            }
        }
    }

    /// Returns the first choice's message content.
    static func complete(_ endpoint: URL, key: String, body: [String: Any], timeout: TimeInterval) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("calhacks-aid/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 {
            let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after")
            throw Failure.rateLimited(retryAfter: header.flatMap(TimeInterval.init) ?? 20)
        }
        guard code == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw Failure.http(code, String((message ?? String(decoding: data, as: UTF8.self)).prefix(160)))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw Failure.unreadable(String(decoding: data.prefix(120), as: UTF8.self))
        }
        return content
    }
}
