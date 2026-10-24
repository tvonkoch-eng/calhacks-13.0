import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A side note for the lens that is not an answer to a question: explaining a niche term,
/// correcting a clearly wrong fact, converting a unit, or supplying the word someone is
/// searching for. Silent almost all the time by design.
public struct SideNote: Sendable, Equatable {
    /// correct | explain | convert | recall
    public let kind: String
    public let note: String
    public let topic: String
}

/// Decides, after each finished sentence that was not a question, whether a side note is worth
/// showing. Runs on gpt-oss-20b, which has its own daily quota on Groq, so it never eats into the
/// answer model's requests. Cheap pre-filter first: most small talk never reaches the model.
@MainActor public final class Aside {
    public let key: String?
    public var model = "openai/gpt-oss-20b"
    /// Never two notes closer than this (seconds): a lens that keeps lighting up is a distraction.
    public var minGap = 8.0
    public private(set) var asked = 0
    /// Names the wearer already knows (team, own tools, venue): never explained. Near-misses
    /// count too, since the recognizer turns "Groq" into "Grog".
    public var known: [String] = []
    private var shown: [String] = []
    private var lastShownAt = -1e9
    private var lastAskedAt = -1e9

    public init(key: String?) { self.key = key }

    /// Worth spending a request on? Needs something a note could be about: a name or term
    /// (capitalised mid-sentence, or an acronym), a number, or someone fishing for a word.
    public static func worthAsking(_ line: String) -> Bool {
        let words = line.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
        guard words.count >= 5 else { return false }
        let lower = line.lowercased()
        if ["what's it called", "whats it called", "what is it called", "the guy who", "the thing that",
            "what's the word", "what's that called", "i forget the name", "what was it called"].contains(where: lower.contains) { return true }
        if line.contains(where: \.isNumber) { return true }
        let ignore: Set<String> = ["I", "I'm", "I'll", "I've", "I'd", "OK", "Okay", "God"]
        return words.dropFirst().contains { w in
            guard let c = w.first, c.isUppercase, !ignore.contains(w) else { return false }
            return true
        }
    }

    public func consider(_ line: String, history: [String], now: Double) async -> SideNote? {
        // A wrong fact is worth showing soon after another note; anything else waits `minGap`.
        guard let key, Self.worthAsking(line), now - lastShownAt > 4, now - lastAskedAt > 2 else { return nil }
        lastAskedAt = now
        asked += 1
        var user = ""
        if !history.isEmpty { user += "Earlier:\n" + history.suffix(4).joined(separator: "\n") + "\n\n" }
        if !known.isEmpty { user += "The wearer already knows these, never explain them: " + known.joined(separator: ", ") + "\n\n" }
        if !shown.isEmpty { user += "Notes already shown: " + shown.suffix(6).joined(separator: "; ") + "\n\n" }
        user += "New line: " + line
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("calhacks-assist/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "temperature": 0, "max_tokens": 400, "reasoning_effort": "low",
            "response_format": ["type": "json_object"],
            "messages": [["role": "system", "content": Self.prompt], ["role": "user", "content": user]],
        ] as [String: Any])
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        Quota.shared.note(response, model: model)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String,
              let v = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
              let kind = v["kind"] as? String, ["correct", "explain", "convert", "recall"].contains(kind),
              let note = (v["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty,
              note.split(separator: " ").count <= 14
        else { return nil }
        let topic = (v["topic"] as? String) ?? ""
        if shown.contains(where: { $0.lowercased() == note.lowercased() }) { return nil }
        if kind != "convert", isKnown(topic) || isKnown(note) { return nil }
        if kind != "correct", now - lastShownAt < minGap { return nil }
        return SideNote(kind: kind, note: note, topic: topic)
    }

    func isKnown(_ topic: String) -> Bool {
        let t = topic.lowercased().filter { $0.isLetter || $0 == " " }
        return known.contains { k in
            let k = k.lowercased().filter { $0.isLetter || $0 == " " }
            return t == k || t.contains(k) || Self.distance(t, k) <= max(1, k.count / 4)
        }
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var d = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var prev = d[0]; d[0] = i
            for j in 1...max(1, b.count) where !b.isEmpty {
                let cur = d[j]
                d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return a.isEmpty ? b.count : d[b.count]
    }

    /// The engine actually put it on the lens.
    public func didShow(_ n: SideNote, at now: Double) {
        shown.append(n.note)
        lastShownAt = now
    }

    public static let prompt = """
    You are a discreet aid on smart glasses worn during an in-person conversation. You see the \
    live transcript. After each new line you may put ONE short side note on the wearer's lens, or \
    nothing. Nothing is the right answer almost every time: a note that is not clearly useful is a \
    distraction.

    Show a note only for one of these:
    - correct: someone states a checkable fact about the world that is clearly wrong. Give the right fact. ("Jupiter has 95 known moons, not 79")
    - explain: a specific proper noun or technical term the wearer may not know (a company, product, place, notable person, acronym, jargon). Say what it is. Skip everyday words, famous things everyone knows, and anything already explained.
    - convert: a number in a unit or currency people often have to convert (Celsius, kilometers, euros, pounds). Give the other unit.
    - recall: the speaker is clearly searching for a word or name ("what's that thing called", "the guy who…"). Supply it.

    Never comment on the people themselves, their feelings, plans, appearance or private life. No \
    advice, opinions, jokes or summaries. Never answer a question (another system does that). If \
    unsure the fact is right, say nothing. The transcript may contain recognition errors: never \
    explain or correct a word that looks misheard.

    Reply with JSON only: {"kind":"none|correct|explain|convert|recall","note":"at most 10 words, no trailing period","topic":"the word or claim it is about, 1-3 words"}
    """
}
