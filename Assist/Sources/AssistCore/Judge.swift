import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A second, bigger model grading what the assistant did with one sentence. Not in the hot path:
/// it runs after the sentence is over, so it can afford a reasoning model.
public struct Verdict: Codable, Sendable {
    /// factual_question | personal_question | not_question | garbled
    public var kind: String
    public var should_answer: Bool
    /// The recognizer got the words right enough to know what was asked.
    public var heard_right: Bool
    /// nil when nothing was shown.
    public var answer_correct: Bool?
    /// 1...5
    public var score: Int
    public var note: String
    public var better_answer: String?

    /// Coarse bucket for the scorecard, computed here rather than trusted from the model.
    public func outcome(shown: Bool) -> String {
        switch (should_answer, shown) {
        case (true, true): answer_correct == false ? "wrong answer" : "answered"
        case (true, false): "missed"
        case (false, true): "should have stayed quiet"
        case (false, false): "correctly quiet"
        }
    }
}

/// What happened to one sentence, written for the judge.
public struct Sentence: Sendable {
    public var text: String
    public var before: [String]
    public var asked: String?
    /// "showed \"330 meters\" 0.54 s before the speaker finished", "nothing shown (skipped as personal)" …
    public var did: String
    public var shown: Bool

    public init(text: String, before: [String], turn: Turn?) {
        self.text = text
        self.before = before
        asked = turn?.question
        shown = false
        guard let turn else {
            did = "nothing shown (did not treat it as a question)"
            return
        }
        switch turn.state {
        case .done, .answering:
            shown = true
            let when = turn.lead.map { $0 >= 0 ? String(format: "%.2f s before the speaker finished", $0)
                                               : String(format: "%.2f s after the speaker finished", -$0) } ?? ""
            did = "showed \"\(turn.answer)\" \(when)"
        case .personal: did = "nothing shown (decided it was about the people talking)"
        case .incomplete: did = "nothing shown (decided the question was too cut off)"
        case .abandoned: did = "nothing shown (decided it was not a question)"
        case .thinking: did = "nothing shown (answer never arrived)"
        case .failed(let e): did = "nothing shown (request failed: \(e))"
        }
    }

    var prompt: String {
        var lines: [String] = []
        if !before.isEmpty { lines.append("Said just before (context only): \"\(before.suffix(2).joined(separator: " "))\"") }
        lines.append("Sentence to grade: \"\(text)\"")
        if let asked { lines.append("Assistant sent the model: \"\(asked)\"") }
        lines.append("Assistant did: \(did)")
        return lines.joined(separator: "\n")
    }
}

public struct Judge: Sendable {
    public let key: String?
    public var model = "openai/gpt-oss-120b"

    public init(key: String?) { self.key = key }

    static var system: String { """
    You grade a live assistant on smart glasses. It listens to an in-person conversation. When \
    someone asks a factual question about the world it shows a short answer (at most 12 words) on \
    the lens, ideally before the speaker finishes. It must stay silent for questions about the \
    people talking (their lives, plans, opinions), for statements, and for requests.

    You get one sentence (a speech-recognizer transcript that may contain recognition errors) and \
    what the assistant did. Judge the speaker's evident intent, not just the literal words. Return \
    JSON only:
    {"kind":"factual_question|personal_question|not_question|garbled","should_answer":true|false,\
    "heard_right":true|false,"answer_correct":true|false|null,"score":1-5,\
    "note":"at most 15 words: what went wrong or right","better_answer":"ideal lens text, or empty"}
    Grade ONLY the Sentence. "Said just before" is there solely to resolve words like it or she; \
    a question asked earlier is graded separately and must not count against this sentence.
    Today is \(Date().formatted(date: .long, time: .omitted)). Your own knowledge may be out of date for facts that change (counts of moons, records, \
    populations, prices, office-holders). If a shown answer is plausible and could be newer than \
    what you know, set answer_correct true and say "unverified" in the note rather than calling \
    it wrong.
    answer_correct is null when nothing was shown. Score 5: right behaviour and a correct, concise \
    answer. Score 1: a wrong answer shown, or an obvious factual question missed. Being late is \
    a smaller fault than being wrong.
    """ }

    public func grade(_ sentence: Sentence) async throws -> Verdict {
        guard let key else { throw AnswerError.unconfigured }
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("calhacks-judge/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "temperature": 0, "max_tokens": 1000, "reasoning_effort": "medium",
            "response_format": ["type": "json_object"],
            "messages": [["role": "system", "content": Self.system], ["role": "user", "content": sentence.prompt]],
        ] as [String: Any])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw AnswerError.http(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw AnswerError.http(0) }
        return try JSONDecoder().decode(Verdict.self, from: Data(content.utf8))
    }
}
