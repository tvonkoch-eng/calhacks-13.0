import Foundation

/// A question spotted in the live transcript.
public struct Candidate: Equatable, Sendable {
    /// The question clause, fillers and lead-ins stripped.
    public let text: String
    /// How sure the local gate is. Only `.strong` is worth spending a speculative request on.
    public let confidence: Confidence
    public let words: Int
    /// Stops mid-phrase ("how tall is the") with no question mark: if the recognizer closes the
    /// sentence here, the rest is probably still coming in the next segment.
    public let unfinished: Bool
    /// Starts with a question word, an auxiliary, or a peeled lead-in (not just a trailing "?").
    public let interrogative: Bool

    public enum Confidence: Sendable { case strong, weak }
}

/// The cheap local gate: does the tail of what we just heard look like a question we could answer?
///
/// Deliberately permissive. It costs ~0 ms and runs on every hypothesis, so it only has to be good
/// enough to decide *whether to start* an answer. The model makes the final call and returns SKIP
/// for anything personal, social or rhetorical that slips through — which is far more accurate than
/// any regex, and by then we've already paid the latency we were trying to hide.
public enum QuestionGate {
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
        // subjects: "what do you", "where did they" always continue
        "you", "we", "i", "they", "he", "she", "people",
        // arithmetic: "what is 17 times" is not a question yet
        "times", "plus", "minus", "divided", "multiplied", "x", "squared", "percent", "point",
    ]

    /// Noise people put in front of a real question.
    private static let fillers: Set<String> = [
        "so", "um", "uh", "er", "like", "well", "wait", "hey", "ok", "okay", "alright",
        "actually", "but", "and", "then", "hmm", "anyway", "yeah", "yo", "dude", "man", "right",
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
        "how was your", "how is your", "how are your", "hows your", "hows the family", "hows work", "whats up", "what is up", "whats new",
        "whats your name", "what do you think", "what do you do", "what do you want",
        "where are you from", "where are we", "where do you live", "when are we", "when are you",
        "are you free", "are you coming", "are you ok", "are you okay", "are you good", "are you sure",
        "do you want", "do you wanna", "did you eat", "did you see", "did you get", "did you go",
        "can you pass", "can you help", "can you hand", "should we", "should i", "can we",
        "do you like", "do you feel", "how do you feel", "what time are we", "whos coming",
    ]

    /// Find the question at the end of `transcript`, if there is one.
    ///
    /// `settled: false` means the last word may still be arriving. Live recognizers stream word
    /// pieces ("the E", "the Eiff", "the Eiffel T"), so an unsettled hypothesis is judged without
    /// its last word unless punctuation already closed it. Otherwise "how tall is the e" looks like
    /// a complete question and we would ask the model about it.
    public static func candidate(in transcript: String, settled: Bool = true) -> Candidate? {
        let whole = evaluate(transcript, settled: settled)
        if let whole, whole.interrogative { return whole }
        // "We're having a conversation, like, how's your run?" — the recognizer used commas, and the
        // question is the last wh-clause. Judge that clause on its own (personal ones still drop out).
        guard let sentence = tail(of: transcript), sentence.contains(",") else { return whole }
        let mark = transcript.trimmed.last.map { ".?!".contains($0) ? String($0) : "" } ?? ""
        let pieces = sentence.components(separatedBy: ",")
        for i in stride(from: pieces.count - 1, to: 0, by: -1) {
            var rest = pieces[i...].joined(separator: ",").trimmed
            let head = strip(fillers, from: normalize(rest)).split(separator: " ").first.map(String.init) ?? ""
            guard wh.contains(head) else { continue }
            if !mark.isEmpty, !rest.hasSuffix(mark) { rest += mark }
            return evaluate(rest, settled: settled)
        }
        return whole
    }

    private static func evaluate(_ transcript: String, settled: Bool) -> Candidate? {
        guard var clause = tail(of: transcript) else { return nil }
        let explicitMark = clause.hasSuffix("?")
        let closed = transcript.trimmed.last.map { ".?!,".contains($0) } ?? false
        let statement = transcript.trimmed.hasSuffix(".")
        clause = normalize(clause)
        // A one- or two-letter tail ("the E", "wall F") is a word still being spoken. Longer
        // pieces ("Eiff") are left in: the model copes, and asking now beats waiting for the word.
        if !settled, !closed, let last = clause.split(separator: " ").last,
           last.count <= 2, !last.contains(where: \.isNumber) {
            clause = clause.split(separator: " ").dropLast().joined(separator: " ")
        }

        clause = strip(fillers, from: clause)
        clause = collapseRestarts(clause)
        // Peel lead-ins, then any fillers they were hiding ("so do you know, uh, how tall …").
        // In a loop: speech restarts stack them up ("do you know, do you know how tall …").
        var peeled = false
        peeling: while true {
            for lead in leadIns where clause == lead || clause.hasPrefix(lead + " ") {
                clause = collapseRestarts(strip(fillers, from: String(clause.dropFirst(lead.count)).trimmed))
                peeled = true
                continue peeling
            }
            break
        }
        guard !clause.isEmpty else { return nil }
        if personal.contains(where: { clause == $0 || clause.hasPrefix($0 + " ") }) { return nil }

        let words = clause.split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        let count = words.count

        // A bare second-person yes/no question is almost always about the listener, not the world.
        // "are you from Denmark" — personal. "do you know where Denmark is" — already peeled above.
        if !peeled, aux.contains(first), count > 1, ["you", "u", "we", "i", "ya"].contains(words[1]) {
            return nil
        }
        // The recognizer closed it with a period: "Was in Berlin last summer." is a statement
        // (with the "I" lost), not a yes/no question.
        if statement, !peeled, aux.contains(first) { return nil }

        let interrogative = wh.contains(first) || aux.contains(first) || peeled
        guard interrogative || explicitMark else { return nil }

        // Strong once there is enough of the clause to guess the whole question *and* the clause
        // does not stop mid-phrase. An explicit "?" from the recognizer means it is definitely done.
        let complete = !dangling.contains(words[count - 1])
        let long = (wh.contains(first) && count >= 3)
            || (aux.contains(first) && count >= 5)
            || (peeled && count >= 3)
        // A "?" on a clause with no question word ("Oh, so fast I was?") is just rising intonation,
        // and volatile hypotheses flip it to "." a moment later. Never fire early on that alone;
        // if the final sentence keeps the "?", the commit still asks the model.
        let strong = (explicitMark && interrogative) || (long && complete)
        // Even "Do you know what?" with a question mark is a sentence the recognizer closed at a pause.
        let unfinished = count < 3 || (!explicitMark && !complete)
        return Candidate(text: clause, confidence: strong ? .strong : .weak, words: count,
                         unfinished: unfinished, interrogative: interrogative)
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
            // "we're" would otherwise become the auxiliary "were" and read as a yes/no question.
            .replacingOccurrences(of: "'re ", with: " are ")
            .replacingOccurrences(of: "\u{2019}re ", with: " are ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Speech restarts: "how how's your run", "do you do you know", "what what is the capital".
    /// Drop a leading word or phrase the speaker immediately said again.
    private static func collapseRestarts(_ clause: String) -> String {
        var words = clause.split(separator: " ").map(String.init)
        // Abandoned start: "how many who won the world cup" -> "who won the world cup". A new
        // question word right after a question word (plus at most one dangling word) restarts it.
        for k in 1...2 where words.count > k + 1 && wh.contains(words[k]) {
            if words[0..<k].allSatisfy({ wh.contains($0) || dangling.contains($0) }), wh.contains(words[0]) {
                words.removeFirst(k)
                break
            }
        }
        var changed = true
        while changed, words.count > 1 {
            changed = false
            for n in stride(from: min(3, words.count / 2), through: 1, by: -1) {
                let head = words[0..<n], next = words[n..<min(words.count, n * 2)]
                // Exact repeat, or a repeat whose last word was cut short ("how" then "how's").
                guard head.count == next.count,
                      zip(head, next).allSatisfy({ $0 == $1 }) ||
                      (head.dropLast().elementsEqual(next.dropLast()) && next.last!.hasPrefix(head.last!))
                else { continue }
                words.removeFirst(n)
                changed = true
                break
            }
        }
        return words.joined(separator: " ")
    }

    private static func strip(_ set: Set<String>, from clause: String) -> String {
        var words = clause.split(separator: " ").map(String.init)
        while let first = words.first, set.contains(first), words.count > 1 { words.removeFirst() }
        return words.joined(separator: " ")
    }
}

extension StringProtocol {
    public var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
