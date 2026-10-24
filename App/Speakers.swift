import Foundation

/// Who said each line, in a conversation of two or more.
///
/// Muse splits turns by voice ("A", "B", "C") but can't know which label is the wearer and which
/// is Avi. Loudness at the phone can't either: a phone on the table is nearer the other person as
/// often as not (Avi's question was ignored as the wearer's own). The signals here, strongest first:
///
/// 1. **The glasses' own transcription** (MWDATSpeech, on-device). Its mics sit at the wearer's
///    mouth and are tuned to the wearer, so the wearer's words show up there and other people's
///    mostly don't. A Muse line whose words the glasses heard too, at the same time, is the
///    wearer's; a long line the glasses heard none of is not. Checked per line, so a Muse label
///    that lumps two voices together can't drag the wearer's lines with it. If the glasses turn
///    out to hear everyone, the signal switches itself off.
///    With the glasses' mic streaming instead (their transcription then can't run), the same idea
///    by level: the phone mic keeps running underneath, and the wearer is much louder at the
///    glasses than at the phone while everyone else is about the same at both. The split between
///    "loud gap" and "small gap" is learned from the conversation itself, so no mic calibration.
/// 2. **Said so**: "That was me" on the phone, or "I'm Toby" from a label.
/// 3. **Introductions**: "I'm Avi" links that label to Avi.
/// 4. **Where the wearer was looking**: you look at whoever is talking when it isn't you. Each of
///    their lines votes for the face in focus while it was said; a few agreeing votes link the
///    label to that person, and the link holds when they're out of view.
///
/// When nothing is conclusive the line belongs to the other person (whoever is in focus): an
/// unanswered question costs more than an answer to your own.
///
/// Pure Foundation, so the rules run in Tests/SpeakersTests.swift without glasses.
struct Speakers {
    enum Who: Equatable {
        case me
        case person(String)
        /// Not the wearer; nobody known.
        case someone
    }

    struct Verdict: Equatable {
        var who: Who
        /// From evidence, not the default.
        var sure: Bool
        var why: String
    }

    /// The wearer's first name, for "I'm Toby".
    var wearer: String
    /// First name (lowercased) → person id, for "I'm Avi".
    var roster: [String: String] = [:]

    // MARK: Tunables

    /// Share of a line's content words the glasses must also have heard for it to be the wearer's.
    static let ownVoiceMatch: Float = 0.5
    /// At or below this share (with the glasses listening), the line is someone else's.
    static let ownVoiceMiss: Float = 0.15
    /// The glasses' text is compared over the line's span widened by this much each side: the two
    /// recognizers run at different delays.
    static let window: TimeInterval = 2.5
    /// Facing votes needed (in lines' worth of focus) before a label is linked to a person.
    static let linkVotes: Float = 2
    static let linkShare: Float = 0.7

    // MARK: State

    private struct Heard {
        let at: Date
        let words: Set<String>
    }
    private var heard: [Heard] = []
    /// Last time the glasses reported anything at all: without it, no line can be ruled "not me".
    private(set) var ownVoiceAt: Date?
    /// False once the glasses have been shown to hear everyone (then the signal means nothing).
    private(set) var ownVoiceTrusted = true
    /// Glasses-minus-phone level of recent lines, to learn where the wearer's gap starts.
    private var gaps: [Float] = []
    /// Two clusters this far apart (dB) or more: one is the wearer.
    static let gapSplit: Float = 6
    /// A line this close to the split is not judged by level.
    static let gapMargin: Float = 1.5
    /// Per line: did the glasses match it, and under which Muse label.
    private var scored: [(label: String, me: Bool)] = []

    /// Labels the wearer locked as theirs, or ruled out.
    private var mine: Set<String> = []
    private var notMine: Set<String> = []
    /// Soft per-label tallies from the glasses' per-line checks.
    private var meTally: [String: (me: Int, other: Int)] = [:]
    /// Label → person, once settled.
    private(set) var links: [String: String] = [:]
    private var votes: [String: [String: Float]] = [:]
    /// Who was in focus, as it changed.
    private var looks: [(at: Date, id: String?)] = []

    init(wearer: String) {
        self.wearer = wearer
    }

    // MARK: Inputs

    /// A transcription result from the glasses' own mic. Partials are cumulative; every one is kept
    /// for a while, since only the words and their time matter.
    mutating func ownVoice(_ text: String, at now: Date = Date()) {
        ownVoiceAt = now
        let words = Self.content(text)
        guard !words.isEmpty else { return }
        heard.append(Heard(at: now, words: words))
        heard.removeAll { now.timeIntervalSince($0.at) > 60 }
    }

    /// The face in focus changed (nil: nobody known in view).
    mutating func looking(at id: String?, at now: Date = Date()) {
        guard looks.last?.id != id || looks.isEmpty else { return }
        looks.append((now, id))
        looks.removeAll { now.timeIntervalSince($0.at) > 120 }
    }

    /// The wearer says this label is theirs.
    mutating func markMe(_ label: String) {
        mine.insert(label)
        notMine.remove(label)
        links[label] = nil
    }

    /// Whether the glasses are hearing the wearer right now (for the turn in progress, before Muse
    /// names its speaker). nil when the glasses' transcription isn't available.
    func wearerTalking(at now: Date = Date()) -> Bool? {
        guard ownVoiceTrusted, let ownVoiceAt, now.timeIntervalSince(ownVoiceAt) < 120 else { return nil }
        return heard.last.map { now.timeIntervalSince($0.at) < 1.5 } ?? false
    }

    /// The face in focus at a moment.
    func focus(at date: Date) -> String? {
        looks.last { $0.at <= date }?.id ?? nil
    }

    // MARK: The decision

    /// Who said a finished Muse line spoken from `start` to `end`.
    mutating func resolve(label: String?, text: String, start: Date, end: Date, gap: Float? = nil) -> Verdict {
        // 1. Their own word, or an introduction.
        if let label, mine.contains(label) { return Verdict(who: .me, sure: true, why: "you said so") }
        if let label, let name = Talk.introducedName(in: text) {
            if name.caseInsensitiveCompare(wearer) == .orderedSame {
                markMe(label)
                return Verdict(who: .me, sure: true, why: "you introduced yourself")
            }
            notMine.insert(label)
            if let id = roster[name.lowercased()] {
                links[label] = id
                return Verdict(who: .person(id), sure: true, why: "introduced themselves")
            }
        }

        // 2. The glasses' own mic.
        if let match = ownVoiceMatch(text, start: start, end: end) {
            let isMe = match >= Self.ownVoiceMatch
            let isOther = match <= Self.ownVoiceMiss
            if let label, isMe || isOther {
                scored.append((label, isMe))
                var tally = meTally[label] ?? (0, 0)
                if isMe { tally.me += 1 } else { tally.other += 1 }
                meTally[label] = tally
                checkTrust()
            }
            if ownVoiceTrusted, isMe { return Verdict(who: .me, sure: true, why: "glasses heard you (\(Int(match * 100))%)") }
            if ownVoiceTrusted, isOther { return other(label, start: start, end: end, sure: true, why: "glasses didn't hear you") }
        }

        // 2b. The glasses' mic against the phone's.
        if let gap {
            gaps.append(gap)
            if gaps.count > 40 { gaps.removeFirst() }
            if let split = gapSplitPoint() {
                if gap >= split + Self.gapMargin {
                    if let label { tally(label, me: true) }
                    return Verdict(who: .me, sure: true, why: String(format: "louder at the glasses (%.0f dB gap)", gap))
                }
                if gap <= split - Self.gapMargin {
                    if let label { tally(label, me: false) }
                    return other(label, start: start, end: end, sure: true, why: String(format: "not louder at the glasses (%.0f dB)", gap))
                }
            }
        }

        // 3. What this label has been so far.
        if let label, ownVoiceTrusted, let tally = meTally[label], tally.me + tally.other >= 1 {
            let share = Float(tally.me) / Float(tally.me + tally.other)
            if share >= 0.8 { return Verdict(who: .me, sure: false, why: "this voice was you before") }
            if share <= 0.2 { return other(label, start: start, end: end, sure: false, why: "this voice wasn't you before") }
        }
        if let label, notMine.contains(label) { return other(label, start: start, end: end, sure: false, why: "not you before") }

        // 4. Default: the other person.
        return other(label, start: start, end: end, sure: false, why: "default")
    }

    private mutating func tally(_ label: String, me: Bool) {
        var t = meTally[label] ?? (0, 0)
        if me { t.me += 1 } else { t.other += 1 }
        meTally[label] = t
    }

    /// Where the recent gaps split into two groups at least `gapSplit` apart (wearer above), if
    /// they do: the midpoint of the widest jump between neighbours, with two lines on each side.
    func gapSplitPoint() -> Float? {
        let sorted = gaps.sorted()
        guard sorted.count >= 4 else { return nil }
        var best: (jump: Float, at: Float)?
        for i in 2..<(sorted.count - 1) where i >= 2 && sorted.count - i >= 2 {
            let low = sorted[..<i], high = sorted[i...]
            let jump = high.reduce(0, +) / Float(high.count) - low.reduce(0, +) / Float(low.count)
            if jump > (best?.jump ?? 0) { best = (jump, (sorted[i - 1] + sorted[i]) / 2) }
        }
        guard let best, best.jump >= Self.gapSplit else { return nil }
        return best.at
    }

    /// Someone other than the wearer said it: which person.
    private mutating func other(_ label: String?, start: Date, end: Date, sure: Bool, why: String) -> Verdict {
        let looked = focusShares(from: start, to: end)
        if let label {
            if sure { notMine.insert(label) }
            for (id, share) in looked { votes[label, default: [:]][id, default: 0] += share }
            relink(label)
            if let id = links[label] { return Verdict(who: .person(id), sure: sure, why: why + " · voice is theirs") }
        }
        if let top = looked.max(by: { $0.value < $1.value }), top.value >= 0.5 {
            return Verdict(who: .person(top.key), sure: false, why: why + " · you were facing them")
        }
        if let id = focus(at: end) { return Verdict(who: .person(id), sure: false, why: why + " · in view") }
        return Verdict(who: .someone, sure: sure, why: why)
    }

    /// Link a label to the person its lines kept facing, or move a link the votes no longer support.
    private mutating func relink(_ label: String) {
        guard let tally = votes[label], let top = tally.max(by: { $0.value < $1.value }) else { return }
        let total = tally.values.reduce(0, +)
        guard top.value >= Self.linkVotes, top.value / total >= Self.linkShare else { return }
        if let current = links[label], current != top.key, (tally[current] ?? 0) + Self.linkVotes > top.value { return }
        links[label] = top.key
    }

    /// Share of [start, end] spent facing each known person.
    private func focusShares(from start: Date, to end: Date) -> [String: Float] {
        let span = max(end.timeIntervalSince(start), 0.5)
        var shares: [String: Float] = [:]
        var cursor = start
        var current = focus(at: start)
        for look in looks where look.at > start && look.at < end {
            if let id = current { shares[id, default: 0] += Float(look.at.timeIntervalSince(cursor) / span) }
            cursor = look.at
            current = look.id
        }
        if let id = current { shares[id, default: 0] += Float(end.timeIntervalSince(cursor) / span) }
        return shares
    }

    /// Share of the line's content words the glasses heard around the same time; nil when the
    /// glasses aren't transcribing or the line is too short to judge.
    func ownVoiceMatch(_ text: String, start: Date, end: Date) -> Float? {
        guard let ownVoiceAt, end.timeIntervalSince(ownVoiceAt) < 120 else { return nil }
        let words = Self.content(text)
        guard words.count >= 2 else { return nil }
        var near = Set<String>()
        for h in heard where h.at >= start.addingTimeInterval(-Self.window) && h.at <= end.addingTimeInterval(Self.window) {
            near.formUnion(h.words)
        }
        return Float(words.intersection(near).count) / Float(words.count)
    }

    /// If the glasses "match" nearly every line from two or more voices, they hear everyone.
    private mutating func checkTrust() {
        guard ownVoiceTrusted, scored.count >= 8 else { return }
        let recent = scored.suffix(12)
        let hits = recent.filter(\.me)
        let labels = Set(hits.map(\.label))
        let perLabel = labels.filter { label in hits.filter { $0.label == label }.count >= 2 }
        if Float(hits.count) / Float(recent.count) > 0.85, perLabel.count >= 2 { ownVoiceTrusted = false }
    }

    // MARK: Text

    static func content(_ text: String) -> Set<String> {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { $0.replacingOccurrences(of: "'", with: "") }
        return Set(words.filter { ($0.count >= 3 || $0.first?.isNumber == true) && !stop.contains($0) })
    }

    private static let stop: Set<String> = [
        "the", "and", "you", "that", "this", "with", "for", "are", "was", "but", "not", "have", "has",
        "its", "it's", "yeah", "yes", "like", "just", "what", "who", "how", "why", "when", "where",
        "they", "them", "she", "her", "him", "his", "our", "your", "from", "about", "there", "here",
        "then", "than", "too", "really", "okay", "right", "know", "think", "can", "will", "would",
        "could", "should", "did", "does", "doing", "been", "were", "all", "any", "some", "one",
        "get", "got", "gonna", "wanna", "kind", "sort", "thing", "things", "mean", "well", "uh", "um",
        "hmm", "mhm", "dont", "im", "ive", "youre", "thats", "its", "theyre", "were", "oh",
    ]
}
