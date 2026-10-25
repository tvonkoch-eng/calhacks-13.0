import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The slow lane. After the other person's sentences and turns, one call looks for a term to
/// define; at the moments Aid picks (a lull, a request, a face just recognised), the same call also
/// writes the best thing for the wearer to say next. The coach decides *what*, Aid decides *when*.
/// What they told us about themselves is the CRM's to keep: its recap reads the whole conversation
/// once it's over, which beats guessing facts line by line. Answers to questions stay in the fast
/// lane (Answer.swift) because they are useless late.
enum Coach {
    /// What the coach sees on each call.
    struct Input {
        var wearer: String
        /// Who the wearer is and what they know: keeps obvious terms from being defined, and gives
        /// suggestions their common ground ("CS and financial math student, trades").
        var background = ""
        /// Where they are ("Cal Hacks 13.0, UC Berkeley"), for questions about here.
        var situation = ""
        var known: String          // "Priya · evals startup founder; Berkeley CS; Last talked Oct 12: …"
        var defined: [String]
        /// Insights already shown (their topics), so none comes round twice.
        var noted: [String] = []
        /// Suggestions already shown, so none comes round twice.
        var suggested: [String]
        /// Why the wearer needs a suggestion right now ("a silence"), or nil: then none is wanted.
        var moment: String?
        var transcript: [String]   // "THEM: …", oldest first; the last one is new
    }

    struct Advice: Equatable {
        var define: [(term: String, meaning: String)] = []
        /// The best thing for the wearer to say next, when one was asked for, and how good the
        /// coach thinks it is (1-5; nil when it didn't say).
        var suggest: String?
        var score: Int?
        /// The runners-up, best first, with their scores: kept for the next lull, so it needs no call.
        var alternatives: [(say: String, score: Int?)] = []
        /// THEM asked for a fact or a task in words the recognizer mangled or left implicit: the
        /// request rebuilt as one clear question, for the answer lane to take.
        var ask: String?
        /// A fact or bit of context about what was just said: a topic (a few words) and the fact.
        var insight: (topic: String, fact: String)?

        static func == (a: Advice, b: Advice) -> Bool {
            a.define.map { "\($0.term)=\($0.meaning)" } == b.define.map { "\($0.term)=\($0.meaning)" }
                && a.suggest == b.suggest && a.score == b.score
                && a.alternatives.map { "\($0.say)=\($0.score ?? 0)" } == b.alternatives.map { "\($0.say)=\($0.score ?? 0)" } && a.ask == b.ask
                && a.insight?.topic == b.insight?.topic && a.insight?.fact == b.insight?.fact
        }
    }

    // Definitions tuned on scripted conversations (Tests/conversations) on 2026-10-23/24: only
    // genuinely obscure terms. A suggestion is asked for only at a moment Aid picked (a silence, a
    // request, a face recognised), so it can aim for the best line rather than the safest. The
    // coach no longer names people (a name mentioned in passing became THEM's) or looks things up
    // (it researched our own product): names come from introductions and face ID, lookups only
    // from questions someone asked.
    static let prompt = """
    You are a quiet conversation aid inside AR glasses. The wearer is in a live, in-person \
    conversation with one or more other people and should stay present in it. Lines are tagged ME \
    (the wearer), the speaker's first name when face ID knows them, or THEM (someone else); THEM \
    below means whoever the wearer is talking with. The transcript comes from live speech recognition, so \
    expect misheard words: read every line as what was clearly meant ("a small evil startup… \
    hiring evil engineers" from someone who does evals → evals, eval engineers; "LOM as a judge" → \
    LLM). Everything you write uses the intended words, never the misheard ones. Questions asked \
    out loud are answered by a separate system; never answer them here.

    Reply with one JSON object with exactly these keys:

    "ask": "..." or null
      The second look at the newest line, from either speaker. A separate system answers \
    questions live but misses some (speech recognition drops the "?", garbles words, or the \
    question is implicit), so whenever the newest line asks for a public fact, a number, a \
    definition, a lookup or a task (something nearby, the weather, the news, a company's latest, \
    "how many law firms are in California", "you know how much figure raised the robot ones", \
    "whats that stable coin bill again"), give it here even if it was phrased clearly: the request \
    as one clear, self-contained question, resolving "it" or "they" from the transcript ("How much \
    did Figure AI raise in its latest round?"). Duplicates are filtered out for you. null if it is \
    personal or social (about the people talking, "how did you get into that", "what are you \
    working on"), rhetorical, already answered in the transcript, or no request at all. A question \
    about this place or event ("how many people are at this thing", "when does it end") only when \
    "Where" names it, resolved to it ("How many attendees does Cal Hacks 13.0 have?"); otherwise null.

    "define": [{"term": "...", "meaning": "..."}]
      At most one: the most interesting technical or specialist term in the newest line, from \
    either speaker: finance (financial derivatives, short selling, a yield curve), science, \
    engineering, medicine, law, a named method or model (Black-Scholes, transformers, CRISPR), a \
    foreign phrase. The point is to make the conversation richer, so lean toward giving one when \
    a line has a real concept or topic in it, even one the wearer roughly knows; when in doubt, give \
    one. A well-known topic counts too (a famous company, place, historical event, field or \
    movement), defined by what is stable about it ("Bauhaus": "1920s German art school; form \
    follows function"); never its latest news, numbers that change, or a private person. Never plain everyday or generic business words (startup, meeting, team, money, \
    app, AI, coding, hackathon). Skip a term the speaker explains in the same breath and pick the \
    next one instead. Speech recognition mangles jargon: if a term looks misheard, define what \
    was clearly meant under its real name ("lawyer adapter" → LoRA adapter), or skip it if \
    unsure. Never define an acronym or word you don't know as an established term: an unfamiliar \
    acronym is usually a misheard familiar one (LOM for LLM), so define the real term only if it \
    is a real concept, otherwise nothing; never invent an expansion. "meaning": what it is in plain words, then one concrete example or striking fact \
    that makes it interesting ("A contract whose value tracks another asset; e.g. options, \
    futures, swaps"), one or two sentences, at most 35 words, with concrete examples ("Contracts whose value \
    tracks another asset, used to hedge or speculate; e.g. options, futures, swaps"). [] when the line has no such term.

    "insight": {"topic": "...", "fact": "..."} or null
      One striking, accurate fact or bit of context about what the newest line is about, that makes \
    the topic more interesting to the wearer: a number, a comparison, a cause, a bit of history, a \
    surprising connection ("topic": "Humanoid robots", "fact": "Figure, Tesla and Agility are \
    racing to put them in warehouses; most still rely on remote operators"). From either speaker. \
    Lean toward giving one whenever the line has a real topic in it (a field, company, place, \
    technology, event, idea); when in doubt, give one. It must be specific and non-obvious: \
    something a smart person in another field likely doesn't know, carried by a name, a number, a \
    date or a comparison ("Jane Street trades over $17 trillion a year"), never a generic statement \
    anyone could guess ("robots improve efficiency") and never what the term means (that is \
    "define"). Only what you are sure of and what doesn't change week to week; never about the \
    people talking or their lives, never about this event or place ("Where"), never advice or a \
    line to say, never a topic in "Already noted". "topic" at most 4 words, "fact" at most 25 \
    words. null for small talk, and null rather than something generic.

    "suggest": [{"say": "...", "score": 1-5}] or null
      Only when "Suggest now" is yes, otherwise null. Up to three different things the wearer \
    could say next, best first, each scored: 5 = specific to this person and moment and clearly \
    better than silence; 3 = good but could be said to anyone like them; 1 = generic. Each one: \
    something to keep the conversation going well: a question for THEM or something to bring up, at most 10 \
    words, in the wearer's voice, no greeting, no name. It is about THEM (their work, what they \
    said, what they're after) or what the two share; never about the wearer's own interests, and \
    never answered already. Draw on, best first:
      - a door THEM just opened that the wearer hasn't walked through: they're hiring, raising, an \
    offer, an invitation, news or a feeling they just shared (the newest thing beats an older thread);
      - what's known about THEM from before: last time's topic, a promise either of them made. \
    Mind whose promise it is: in "Known about them", the wearer's name means the wearer ("Toby \
    promised to send the video" is the wearer's promise). One the wearer made is offered, never \
    asked about ("Want me to send you the demo video?"); one THEM made can be asked about;
      - a thread THEM opened that nobody followed up: a project, a problem, a plan, news;
      - something they have in common, going only by the wearer's background;
      - when the conversation winds down: a concrete next step (swap contacts, an intro, a follow-up).
      Specific to this person and this conversation; a simple open question only when nothing is \
    known yet. Never a reply on the wearer's behalf or a claim about their life, never a quiz \
    about a term, never a thread already covered, never one of "Already suggested", never filler \
    or praise ("That's awesome", "Tell me more"). With several people, aim it at whoever the \
    moment is about and use what they share. When the wearer asks, always give one.
    """

    static func message(_ input: Input) -> String {
        func list(_ items: [String]) -> String { items.isEmpty ? "none" : items.joined(separator: ", ") }
        return """
        Wearer: \(input.wearer)\(input.background.isEmpty ? "" : " (\(input.background))")
        Where: \(input.situation.isEmpty ? "unknown" : input.situation)
        Known about them: \(input.known.isEmpty ? "nothing yet" : input.known)
        Already defined: \(list(input.defined))
        Already noted: \(list(input.noted))
        Already suggested: \(input.suggested.isEmpty ? "none" : input.suggested.map { "\"\($0)\"" }.joined(separator: ", "))
        Suggest now: \(input.moment.map { "yes (\($0))" } ?? "no")

        Transcript (oldest first; the last line is new):
        \(input.transcript.isEmpty ? "(nothing said yet)" : input.transcript.joined(separator: "\n"))
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
        // JSON is short, but reasoning models (gpt-oss, Muse Spark) think before writing any of it.
        if model.contains("gpt-oss") {
            body.merge(["max_tokens": 1200, "reasoning_effort": "low"]) { _, new in new }
        } else if provider == .cerebras || provider == .openrouter, model.contains("qwen") {
            // Room for three scored suggestions as well as a definition.
            body.merge(["max_tokens": 420, "reasoning_effort": "none"]) { _, new in new }
        } else if provider == .muse {
            body.merge(["max_tokens": 900, "reasoning_effort": "minimal"]) { _, new in new }
        } else {
            body["max_tokens"] = 220
        }
        // Not every host takes JSON mode; the parser copes with prose around the object anyway.
        if provider == .cerebras { body.removeValue(forKey: "response_format") }
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
        result.define = terms.prefix(1).compactMap { entry in
            guard let term = clean(entry["term"]), let meaning = clean(entry["meaning"]) else { return nil }
            return (term, meaning)
        }
        // A list of {"say", "score"} best first; one string from a model that ignored the shape.
        if let options = object["suggest"] as? [Any] {
            let lines = options.compactMap { option -> (String, Int?)? in
                if let say = clean(option) { return (say, nil) }
                guard let entry = option as? [String: Any], let say = clean(entry["say"] ?? entry["text"]) else { return nil }
                return (say, (entry["score"] as? NSNumber)?.intValue)
            }
            result.suggest = lines.first?.0
            result.score = lines.first?.1
            result.alternatives = lines.dropFirst().map { (say: $0.0, score: $0.1) }
        } else {
            result.suggest = clean(object["suggest"])
        }
        result.ask = clean(object["ask"])
        if let insight = object["insight"] as? [String: Any], let topic = clean(insight["topic"]), let fact = clean(insight["fact"]) {
            result.insight = (topic, fact)
        }
        return result
    }
}

// MARK: - Research

/// The deeper lane: turn a question into one glanceable line, taking seconds rather than
/// milliseconds. Anything can sit behind this — a web-search model, a Fetch.ai agent on Agentverse,
/// a company database. Only questions someone asked reach it, and only public ones: the answer lane
/// says WEB, or the tool model calls `research`. Never the people in the conversation.
protocol Researcher: Sendable {
    var name: String { get }
    func research(_ query: String, context: String) async throws -> String
}

/// Fetch.ai's ASI:One, through its Responses endpoint with the web_search tool: measured on
/// 2026-10-24, `asi1` searched and answered current questions in ~4.3 s ("OCC finalized its
/// stablecoin rule Oct 21…"), twice as fast as OpenAI's search model. `asi1-mini` never searched
/// (and was wrong); `asi1-ultra` took 9-18 s. The chat endpoint rejects `web_search` and 500s on
/// it as a tool, so it has to be Responses.
struct ASIOne: Researcher {
    let key: String
    var model = "asi1"
    var name: String { "Fetch.ai ASI:One" }

    func research(_ query: String, context: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.asi1.ai/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "instructions": """
                You look things up for someone mid-conversation who will glance at your reply on \
                smart glasses. Reply with the single most useful thing to know, at most 18 words, \
                plain text, no citations, no preamble. Search only for the public subject of the \
                question; the conversation is there to resolve "it" or "that bill", and the people \
                in it are never searched for.
                """,
            "input": context.isEmpty ? query : "Look up: \(query)\n\nConversation so far:\n\(context)",
            "tools": [["type": "web_search"]],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 { throw LLM.Failure.rateLimited(retryAfter: 20) }
        guard code == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLM.Failure.http(code, String(decoding: data.prefix(160), as: UTF8.self))
        }
        // Output is reasoning, a search call, and messages; the answer is the last message's text.
        let texts = ((json["output"] as? [[String: Any]]) ?? [])
            .filter { $0["type"] as? String == "message" }
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["type"] as? String == "output_text" ? ($0["text"] as? String) : nil }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let answer = texts.last else { throw LLM.Failure.unreadable("no answer in ASI:One output") }
        return answer
    }
}

/// Any OpenAI-compatible chat endpoint with web search built in:
/// - `groq`: gpt-oss-120b with Groq's browser_search tool (~3 s, but ~20k tokens a lookup, which
///   is a tenth of Groq's free daily budget).
/// - `openai`: gpt-5-search-api (~7-8 s, ~17k tokens).
/// Search models ignore length limits, so findings are cut down to a card (`Tools.card`).
struct WebResearcher: Researcher {
    let name: String
    let endpoint: URL
    let key: String
    let model: String
    /// Provider-specific request fields, as JSON text so the struct stays Sendable.
    let extra: String
    var timeout: TimeInterval = 25

    static func groq(key: String) -> WebResearcher {
        WebResearcher(name: "Groq web search", endpoint: Provider.groq.endpoint, key: key,
                      model: "openai/gpt-oss-120b",
                      extra: #"{"tools":[{"type":"browser_search"}],"reasoning_effort":"low","max_tokens":2000}"#)
    }

    static func openai(key: String) -> WebResearcher {
        WebResearcher(name: "OpenAI web search", endpoint: Provider.openai.endpoint, key: key,
                      model: "gpt-5-search-api", extra: #"{"web_search_options":{}}"#)
    }

    func research(_ query: String, context: String) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": """
                    You look things up for someone mid-conversation who will glance at your reply on \
                    smart glasses. Reply with the single most useful thing to know, at most 18 words, \
                    plain text, no citations, no preamble. Search only for the public subject of \
                    the question; never for the people in the conversation.
                    """],
                ["role": "user", "content": "Look up: \(query)\n\nConversation so far:\n\(context)"],
            ],
        ]
        if let fields = try? JSONSerialization.jsonObject(with: Data(extra.utf8)) as? [String: Any] {
            body.merge(fields) { _, new in new }
        }
        let text = try await LLM.complete(endpoint, key: key, body: body, timeout: timeout)
        // Strip search citations (【1†L11-L13】) and markdown emphasis.
        let plain = text.replacingOccurrences(of: #"【[^】]*】"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { throw LLM.Failure.unreadable("empty research reply") }
        return plain
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
    static func complete(_ endpoint: URL, key: String, body: [String: Any], timeout: TimeInterval,
                         headers: [String: String] = [:]) async throws -> String {
        let reply = try await chat(endpoint, key: key, body: body, timeout: timeout, headers: headers)
        guard let content = reply.content else { throw Failure.unreadable("no content") }
        return content
    }

    struct Reply {
        var content: String?
        var calls: [(name: String, arguments: String)]
    }

    /// The first choice's message: its text and any tool calls. Claude's endpoint gets the same
    /// OpenAI-shaped body, translated (`Claude.body`), so every lane can run on it unchanged.
    static func chat(_ endpoint: URL, key: String, body: [String: Any], timeout: TimeInterval,
                     headers: [String: String] = [:]) async throws -> Reply {
        let claude = endpoint == Claude.endpoint
        var request = URLRequest(url: endpoint)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        Claude.authorize(&request, key: key, claude: claude)
        request.setValue("calhacks-aid/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: claude ? Claude.body(body)
            : endpoint == OpenRouter.endpoint ? OpenRouter.adjust(body) : body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 {
            let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after")
            throw Failure.rateLimited(retryAfter: header.flatMap(TimeInterval.init) ?? 20)
        }
        // Out of quota ("payment required", Cerebras on 2026-10-24): the same as a long rate limit,
        // so every lane goes to its backup instead of failing.
        if code == 402 { throw Failure.rateLimited(retryAfter: 600) }
        guard code == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw Failure.http(code, String((message ?? String(decoding: data, as: UTF8.self)).prefix(160)))
        }
        if claude {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.unreadable(String(decoding: data.prefix(120), as: UTF8.self))
            }
            return Claude.reply(json)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else {
            throw Failure.unreadable(String(decoding: data.prefix(120), as: UTF8.self))
        }
        let calls = ((message["tool_calls"] as? [[String: Any]]) ?? []).compactMap { call -> (String, String)? in
            guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
            return (name, function["arguments"] as? String ?? "{}")
        }
        return Reply(content: message["content"] as? String, calls: calls)
    }
}

// MARK: - Claude

/// Claude's Messages API behind the same OpenAI-shaped requests the lanes already build: the
/// system message moves to `system`, `reasoning_effort` becomes `output_config.effort`, tools
/// become Claude tools, and the reply comes back as an `LLM.Reply`. Sampling knobs (`temperature`)
/// and JSON mode are dropped: this API version rejects the first, and the parsers cope without
/// the second. Pure, so the request shape is tested offline (Tests/AidTests.swift).
enum Claude {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let version = "2026-10-21"

    static func authorize(_ request: inout URLRequest, key: String, claude: Bool) {
        if claude {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue(version, forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    static func body(_ chat: [String: Any]) -> [String: Any] {
        let messages = (chat["messages"] as? [[String: Any]]) ?? []
        let system = messages.filter { $0["role"] as? String == "system" }.compactMap { $0["content"] as? String }
        let model = chat["model"] as? String ?? ""
        var body: [String: Any] = [
            "model": model,
            "messages": messages.filter { $0["role"] as? String != "system" }
                .map { ["role": $0["role"] as? String ?? "user", "content": $0["content"] as? String ?? ""] },
        ]
        if !system.isEmpty { body["system"] = system.joined(separator: "\n\n") }
        if chat["stream"] as? Bool == true { body["stream"] = true }

        // "none" is a lane asking for no thinking at all (a 12-word answer). Sonnet 5.5 turns it
        // off with between_tools, Haiku with disabled; Opus and Fable always think, so they get
        // the least. Thinking counts against max_tokens, so a lane's tiny budget gets room.
        let asked = chat["reasoning_effort"] as? String ?? "low"
        var thinking = true
        if asked == "none" || asked == "minimal" {
            if model.contains("sonnet-5-5") { body["thinking"] = ["type": "between_tools"]; thinking = false }
            else if model.contains("haiku") { body["thinking"] = ["type": "disabled"]; thinking = false }
        }
        body["output_config"] = ["effort": ["low", "medium", "high"].contains(asked) ? asked : "low"]
        let budget = chat["max_tokens"] as? Int ?? 1024
        body["max_tokens"] = thinking ? max(budget, 2048) : max(budget, 64)

        if let tools = chat["tools"] as? [[String: Any]] {
            body["tools"] = tools.compactMap { tool -> [String: Any]? in
                guard let function = tool["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
                return ["name": name, "description": function["description"] as? String ?? "",
                        "input_schema": function["parameters"] ?? ["type": "object", "properties": [String: Any]()]]
            }
            body["tool_choice"] = ["type": "auto"]
        }
        return body
    }

    /// The text blocks joined, and any tool calls with their input as JSON text.
    static func reply(_ json: [String: Any]) -> LLM.Reply {
        let blocks = (json["content"] as? [[String: Any]]) ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        let calls = blocks.filter { $0["type"] as? String == "tool_use" }.compactMap { block -> (String, String)? in
            guard let name = block["name"] as? String else { return nil }
            let input = (try? JSONSerialization.data(withJSONObject: block["input"] ?? [String: Any]()))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return (name, input)
        }
        return LLM.Reply(content: text.isEmpty ? nil : text, calls: calls)
    }

    /// One server-sent event's text, if it carries any (`content_block_delta` / `text_delta`).
    static func delta(_ payload: String) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              json["type"] as? String == "content_block_delta",
              let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta" else { return nil }
        return delta["text"] as? String
    }
}

// MARK: - Exa

/// Exa's search API: ranked pages with the sentences that matter, in well under a second
/// (an independent benchmark on 2026-10-21 put Exa's fast modes at 0.4-0.65 s mean against
/// 4-8 s for ASI:One here). Exa only searches, so the question is first made self-contained
/// from the conversation ("how much did they raise" → "Figure AI latest funding round") by the
/// fast model, and Aid's condenser cuts the findings to a card as it does for every researcher.
struct Exa: Researcher {
    let key: String
    /// Exa's search type: "instant", its real-time mode (measured 0.4-0.5 s, 0.09 s repeated),
    /// by default; "fast" or "auto" via RESEARCH_MODEL.
    var type = "instant"
    /// Rewrites a question that leans on the conversation into a standalone query.
    var resolver: (provider: Provider, key: String, model: String)?
    var name: String { "Exa" }

    func research(_ query: String, context: String) async throws -> String {
        var search = query
        // Resolve against the conversation when the question leans on it, and always when we know
        // where they are: "the closing ceremony" alone found the FIFA World Cup's.
        if let resolver, !context.isEmpty, Self.leans(query) || context.contains("Where:") {
            search = (try? await LLM.complete(resolver.provider.endpoint, key: resolver.key, body: [
                "model": resolver.model,
                "max_tokens": 40,
                "reasoning_effort": resolver.model.contains("gpt-oss") ? "low" : "none",
                "messages": [
                    ["role": "system", "content": """
                        Rewrite the question as one standalone web search query, resolving "it", "they" \
                        or "that" from the conversation. Public subjects only, never the people talking. \
                        Reply with the query alone.
                        """],
                    ["role": "user", "content": "Conversation:\n\(context)\n\nQuestion: \(query)"],
                ],
            ], timeout: 3))?.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n")) ?? query
            if search.isEmpty { search = query }
        }
        var request = URLRequest(url: URL(string: "https://api.exa.ai/search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Exa's recommended request (query plus highlights), with fewer results than its 10: a
        // card needs one fact, and four pages keep the condenser's prompt small and quick.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": search,
            "type": type,
            "numResults": 4,
            "contents": ["highlights": true],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 { throw LLM.Failure.rateLimited(retryAfter: 10) }
        guard code == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLM.Failure.http(code, String(decoding: data.prefix(160), as: UTF8.self))
        }
        let findings = Self.findings(json)
        guard !findings.isEmpty else { throw LLM.Failure.unreadable("no Exa results for \(search)") }
        return "Search: \(search)\n" + findings
    }

    /// "how much did they raise", "when does it ship": a question that needs the conversation.
    static func leans(_ query: String) -> Bool {
        let words = Set(Talk.normalized(query).split(separator: " ").map(String.init))
        return !words.isDisjoint(with: ["it", "its", "they", "their", "them", "that", "this", "those", "these",
                                        "he", "she", "his", "her", "there", "one", "here", "thing"])
    }

    /// One line per result: title, date, highlights.
    static func findings(_ json: [String: Any]) -> String {
        ((json["results"] as? [[String: Any]]) ?? []).prefix(4).compactMap { result -> String? in
            let highlights = ((result["highlights"] as? [String]) ?? []).joined(separator: " … ")
            let text = highlights.isEmpty ? String((result["text"] as? String ?? "").prefix(400)) : highlights
            guard !text.isEmpty else { return nil }
            let date = (result["publishedDate"] as? String).map { " (\($0.prefix(10)))" } ?? ""
            return "- \(result["title"] as? String ?? "")\(date): \(text)"
        }.joined(separator: "\n")
    }
}

// MARK: - OpenRouter

/// OpenRouter is OpenAI-compatible, but picks a host per request: ask for Cerebras, then Groq
/// (the fastest for our models), falling back to whoever has capacity. Its reasoning switch is
/// `reasoning`, not `reasoning_effort`; Qwen thinks unless told not to.
enum OpenRouter {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    static func adjust(_ chat: [String: Any]) -> [String: Any] {
        var body = chat
        let effort = body.removeValue(forKey: "reasoning_effort") as? String
        let model = body["model"] as? String ?? ""
        if effort == "none" || (effort == nil && model.contains("qwen")) {
            body["reasoning"] = ["enabled": false]
        } else if let effort {
            body["reasoning"] = ["effort": effort == "minimal" ? "low" : effort]
        }
        body["provider"] = ["order": ["cerebras", "groq"], "allow_fallbacks": true]
        // JSON mode sends the request to a host that supports it, not Cerebras (0.6 s became ~6 s
        // for the coach). The parsers take JSON wrapped in prose anyway.
        body.removeValue(forKey: "response_format")
        return body
    }
}
