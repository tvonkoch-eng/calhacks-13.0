import Foundation

/// A question spotted in the live transcript.
struct Candidate: Equatable {
    /// The question clause, fillers and lead-ins stripped.
    let text: String
    /// How sure the local gate is. Only `.strong` is worth spending a speculative request on.
    let confidence: Confidence
    let words: Int

    enum Confidence { case strong, weak }
}

/// The cheap local gate: does the tail of what we just heard look like a question we could answer?
///
/// Deliberately permissive. It costs ~0 ms and runs on every hypothesis, so it only has to be good
/// enough to decide *whether to start* an answer. The model makes the final call and returns SKIP
/// for anything personal, social or rhetorical that slips through — which is far more accurate than
/// any regex, and by then we've already paid the latency we were trying to hide.
enum QuestionGate {
    /// Words that make a clause a question all by themselves.
    private static let wh: Set<String> = [
        "who", "whos", "what", "whats", "when", "whens", "where", "wheres",
        "why", "whys", "how", "hows", "which", "whose", "whom",
    ]

    /// Auxiliaries that signal a yes/no question when they lead the clause.
    private static let aux: Set<String> = [
        "is", "isnt", "are", "arent", "was", "wasnt", "were", "do", "does", "did", "didnt",
        "can", "cant", "could", "will", "wont", "would", "has", "hasnt", "have", "had", "may", "might",
    ]

    /// Words that mean the clause is still mid-phrase. Speculating on "how tall is the" is wasted —
    /// the subject has not been said yet — so a clause ending in one of these is never `.strong`.
    private static let dangling: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "your", "his", "her", "its",
        "our", "their", "of", "in", "on", "at", "to", "for", "from", "with", "about", "by",
        "into", "than", "as", "between", "near", "over", "under", "and", "or", "but", "if", "so",
        "is", "are", "was", "were", "do", "does", "did", "has", "have", "had", "can", "could",
        "will", "would", "should", "be", "been", "being", "am", "very", "really", "most", "more",
        "much", "many", "about", "like",
    ]

    /// Noise people put in front of a real question.
    private static let fillers: Set<String> = [
        "so", "um", "uh", "er", "like", "well", "wait", "hey", "ok", "okay", "alright",
        "actually", "but", "and", "then", "hmm", "anyway", "yeah", "yo", "dude", "man", "right",
        "oh", "ah", "interesting", "cool", "nice", "wow", "huh", "gotcha", "sure", "honestly", "basically",
    ]

    /// Lead-ins that wrap a real question. Stripped so the inner clause gets judged on its merits:
    /// "do you know how big the sun is" must survive the second-person check below.
    private static let leadIns = [
        "do you know", "does anyone know", "do you happen to know", "anyone know", "anybody know",
        "any idea", "i wonder", "im wondering", "i was wondering", "tell me", "remind me",
        "do you have any idea", "quick question", "question for you", "can you tell me",
        "whats your guess on", "do we know",
    ]

    /// Clauses about the people talking, not about the world. Cheap pre-filter; the model backstops it.
    private static let personal = [
        "how are you", "how are we", "how r u", "how you doing", "how is it going", "hows it going",
        "how was your", "how is your", "how are your", "whats up", "what is up", "whats new",
        "whats your name", "what do you think", "what do you do", "what do you want",
        "where are you from", "where are we", "where do you live", "when are we", "when are you",
        "are you free", "are you coming", "are you ok", "are you okay", "are you good", "are you sure",
        "do you want", "do you wanna", "did you eat", "did you see", "did you get", "did you go",
        "can you pass", "can you help", "can you hand", "should we", "should i", "can we",
        "do you like", "do you feel", "how do you feel", "what time are we", "whos coming",
        "what about you", "how about you", "and you", "what about yourself", "how did you end up",
        "how did you get into", "what brings you", "what are you working on", "what are you up to",
        "how was it", "how was that", "how did it go", "how did that go", "what was it like",
        "what was that like", "how is that going", "hows that going", "how is it", "hows it",
    ]

    /// "how do you think about …", "what would you choose": asking for the listener's view.
    private static let opinion: Set<String> = [
        "think", "feel", "see", "view", "approach", "decide", "handle", "deal", "like", "find", "choose",
        "pick", "recommend", "suggest", "rate", "rank", "manage", "prefer", "make",
    ]

    /// Find the question at the end of `transcript`, if there is one.
    static func candidate(in transcript: String) -> Candidate? {
        guard var clause = tail(of: transcript) else { return nil }
        let explicitMark = clause.hasSuffix("?")
        clause = normalize(clause)

        clause = strip(fillers, from: clause)
        // Peel lead-ins, then any fillers they were hiding ("so do you know, uh, how tall …").
        var peeled = false
        for lead in leadIns where clause == lead || clause.hasPrefix(lead + " ") {
            clause = strip(fillers, from: String(clause.dropFirst(lead.count)).trimmed)
            peeled = true
            break
        }
        guard !clause.isEmpty else { return nil }
        // "congrats, how was it?", "last thing, is there a coffee place near here?": with a question
        // mark, a few leading words before the question word or auxiliary are an interjection.
        // Without one, "the guy who wrote it" is not a question.
        if explicitMark, !peeled {
            let words = clause.split(separator: " ").map(String.init)
            if let first = words.first, !wh.contains(first), !aux.contains(first),
               let at = words.prefix(4).firstIndex(where: { wh.contains($0) || aux.contains($0) }), at > 0 {
                clause = words[at...].joined(separator: " ")
            }
        }
        // A question buried in run-on talk with no full stop before it ("so I was telling him
        // about it how many moons does Jupiter have"): start at the last question word that is
        // followed by an auxiliary within three words, so "what you mean" or "how much it cost"
        // never count.
        if !peeled {
            let words = clause.split(separator: " ").map(String.init)
            if let first = words.first, !wh.contains(first), !aux.contains(first), words.count >= 5,
               let at = words.indices.last(where: { i in
                   i > 0 && wh.contains(words[i]) && words[(i + 1)..<min(words.count, i + 4)].contains { aux.contains($0) }
               }), words.count - at >= 4 {
                clause = words[at...].joined(separator: " ")
            }
        }
        if personal.contains(where: { clause == $0 || clause.hasPrefix($0 + " ") }) { return nil }

        let words = clause.split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        let count = words.count

        // A bare second-person yes/no question is almost always about the listener, not the world.
        // "are you from Denmark" — personal. "do you know where Denmark is" — already peeled above.
        if !peeled, aux.contains(first), count > 1, ["you", "u", "we", "i", "ya"].contains(words[1]) {
            return nil
        }

        // "how did you end up …", "where did you grow up": a past-tense question to the listener
        // is about them. So is asking how they think, see or decide. (Present "how do you say X" is
        // usually the generic you, so it stays.)
        if !peeled, wh.contains(first), count > 2, ["you", "u", "ya"].contains(words[2]) {
            if ["did", "have", "were", "had", "didnt"].contains(words[1]) { return nil }
            if ["do", "would"].contains(words[1]), count > 3, opinion.contains(words[3]) { return nil }
        }

        // A question mark alone isn't enough: "like live captions?", "really?", "no way?" are the
        // listener reacting, not asking anything the lens could answer.
        let interrogative = wh.contains(first) || aux.contains(first) || peeled
        guard interrogative else { return nil }

        // Strong once there is enough of the clause to guess the whole question *and* the clause
        // does not stop mid-phrase. An explicit "?" from the recognizer means it is definitely done.
        let settled = !dangling.contains(words[count - 1])
        let long = (wh.contains(first) && count >= 4)
            || (aux.contains(first) && count >= 5)
            || (peeled && count >= 3)
        let strong = explicitMark || (long && settled)
        return Candidate(text: clause, confidence: strong ? .strong : .weak, words: count)
    }

    /// Last sentence of the transcript — the one still being spoken.
    private static func tail(of transcript: String) -> String? {
        let parts = transcript.split(whereSeparator: { ".?!".contains($0) })
        guard let last = parts.last?.trimmed, !last.isEmpty else {
            // Transcript is just "?" or "." — fall back to the piece before it.
            return parts.dropLast().last?.trimmed
        }
        // Keep the mark so an explicit "?" still counts.
        if let mark = transcript.trimmed.last, "?".contains(mark), parts.count > 1 {
            return (parts[parts.count - 1].trimmed) + "?"
        }
        return transcript.trimmed.hasSuffix("?") ? last + "?" : last
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            // Expand before apostrophes go, or "we're doing" reads as the question "were doing".
            .replacingOccurrences(of: "'re\\b", with: " are", options: .regularExpression)
            .replacingOccurrences(of: "'ll\\b", with: " will", options: .regularExpression)
            .replacingOccurrences(of: "'ve\\b", with: " have", options: .regularExpression)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func strip(_ set: Set<String>, from clause: String) -> String {
        var words = clause.split(separator: " ").map(String.init)
        while let first = words.first, set.contains(first), words.count > 1 { words.removeFirst() }
        return words.joined(separator: " ")
    }
}

extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
