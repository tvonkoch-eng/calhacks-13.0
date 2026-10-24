import CoreLocation
import Foundation
import Observation

/// One speaker turn, as Muse heard it.
struct Line: Identifiable, Equatable {
    let id: Int
    /// Muse's diarization label ("A", "B"); nil when the recognizer didn't say.
    var speaker: String?
    var text: String
    var at: Date
    /// "Lens, …": said to the glasses, not to the other person, so the coach never sees it.
    var command = false
}

/// One question we heard and what we did about it.
struct Turn: Identifiable {
    let id = UUID()
    /// The lens card for this answer; refires of the same question keep it.
    let card: Int
    var question: String
    var answer = ""
    var state: State = .thinking
    var fires = 0

    var firedAt = Date()
    var shownAt: Date?
    var committedAt: Date?
    /// The model said the answer needs the web; it's looked up once the question has closed.
    var lookup = false

    enum State: Equatable { case thinking, answering, done, skipped, failed(String) }

    /// How far ahead of the end of the question the first words hit the lens.
    /// Positive means the answer was already up there before they stopped talking.
    var lead: TimeInterval? {
        guard let shownAt, let committedAt else { return nil }
        return committedAt.timeIntervalSince(shownAt)
    }

    var live: Bool { state == .thinking || state == .answering }
}

/// Everything the aid did, in order: the phone's timeline, the Mac tool's log.
struct Event: Identifiable, Equatable {
    enum Kind: Equatable { case line, answer, define, followup, research, lookup, learned, roles, status }
    let id: Int
    let kind: Kind
    let text: String
    var detail = ""
    /// For lines: the diarization label. Tag it with `Aid.tag` at display time, since who's who
    /// can be learned after the line was heard.
    var speaker: String?
    let at: Date
}

/// Who the other person is: what face ID and the CRM know about them (`Aid.met`: profile, last
/// conversation, promises) and the name they introduce themselves with. Every lane reads it as
/// "known about them"; what they say now is in the transcript every lane also gets.
struct Them: Equatable {
    var name: String?
    var label: String?
    var facts: [String] = []
    /// Set by face ID (`Aid.met`). A recognised face beats a name heard through the recognizer, so
    /// the coach no longer renames them.
    var recognised = false

    var header: String? {
        let parts = [name, label].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var summary: String {
        ([header].compactMap { $0 } + facts).joined(separator: "; ")
    }
}

/// Which diarization label is the wearer. Signals, weakest first:
/// 1. Loudness. The wearer's mouth is closest to the mic, so their turns run louder. A guess,
///    revised as turns come in.
/// 2. Introductions: "I'm Priya" from A means A is the other person; "I'm Toby" from the wearer
///    means them. Locks it. (Deliberately not the model: asked to infer this, gpt-4.1-mini got it
///    backwards on the same transcript it had got right a run earlier.)
/// 3. Behavior: whoever just said the pinned follow-up is the wearer. Locks it.
/// 4. The wearer says so (tap a line in the app, `m` in the Mac tool). Locks it.
struct Roles: Equatable {
    private(set) var wearer: String?
    private(set) var sure = false
    private var total: [String: Float] = [:]
    private var count: [String: Int] = [:]
    private var seen: Set<String> = []
    /// Known to be the other person before the wearer's label has been heard.
    private var them: String?

    /// Gap in mean turn loudness that counts as "closer to the mic".
    static let margin: Float = 3

    var known: Bool { wearer != nil }

    mutating func heard(_ label: String, level: Float?) {
        seen.insert(label)
        if let them, !sure, label != them { lock(label) }
        guard let level, level > -90 else { return }
        total[label, default: 0] += level
        count[label, default: 0] += 1
        guard !sure, total.count >= 2 else { return }
        let means = total.map { ($0.key, $0.value / Float(count[$0.key] ?? 1)) }.sorted { $0.1 > $1.1 }
        if means[0].1 - means[1].1 >= Self.margin { wearer = means[0].0 }
    }

    mutating func lock(_ label: String) {
        wearer = label
        sure = true
    }

    /// `label` is the other person; the wearer is whoever else speaks.
    mutating func lock(them label: String) {
        if let other = seen.first(where: { $0 != label }) { lock(other) } else { them = label }
    }

    func isWearer(_ label: String?) -> Bool { label != nil && label == wearer }

    /// ME / THEM once we know who's who, the raw label until then.
    func tag(_ label: String?) -> String {
        guard let label else { return "?" }
        guard let wearer else { return label }
        return label == wearer ? "ME" : "THEM"
    }
}

/// Small text rules the lanes share. Pure; tested in Tests/AidTests.swift.
enum Talk {
    /// "yeah", "oh wow", "mm-hmm": a listener noise, not a turn worth coaching on.
    static func isBackchannel(_ text: String) -> Bool {
        let words = normalized(text).split(separator: " ")
        guard !words.isEmpty, words.count <= 3 else { return false }
        return words.allSatisfy { backchannel.contains(String($0)) }
    }

    /// Did `line` just say `suggestion`? Most of the suggestion's content words, in any order; for a
    /// short suggestion with one content word ("What does Rillet do?"), nearly all of its words.
    static func echoes(_ line: String, _ suggestion: String) -> Bool {
        let wanted = content(suggestion)
        if wanted.count >= 2 {
            return Double(wanted.intersection(content(line)).count) / Double(wanted.count) >= 0.6
        }
        let all = Set(normalized(suggestion).split(separator: " ").map(String.init))
        let said = Set(normalized(line).split(separator: " ").map(String.init))
        return !all.isEmpty && Double(all.intersection(said).count) / Double(all.count) >= 0.8
    }

    /// Was `term` (or, for a misheard term defined under its real name, most of its longer words)
    /// just said? Keeps the coach from defining things from three minutes ago.
    static func mentioned(_ term: String, in recent: String) -> Bool {
        let said = Set(recent.split(separator: " ").map(String.init))
        let parts = normalized(term).split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return false }
        if recent.contains(normalized(term)) { return true }
        let long = parts.filter { $0.count >= 4 }
        guard !long.isEmpty else { return parts.allSatisfy(said.contains) }
        return Double(long.filter { word in said.contains { $0.hasPrefix(String(word.prefix(4))) } }.count) / Double(long.count) >= 0.5
    }

    /// "No, this is my first hackathon": a reply on the wearer's behalf, claiming things about them
    /// the aid can't know. A suggestion asks or says something to the other person instead.
    static func speaksForWearer(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").trimmingCharacters(in: .whitespaces)
        return ["no,", "no ", "nope", "yes", "yeah", "yep", "i ", "i'm", "i've", "i'd", "i'll", "my ", "me "]
            .contains { t.hasPrefix($0) }
    }

    /// "what time does it start", "you know how much they raised", "Do you know X?": a request for
    /// something, as opposed to a statement ("we just raised a seed round").
    static func asks(_ text: String) -> Bool {
        if text.contains("?") { return true }
        let t = " " + normalized(text) + " "
        return [" what ", " when ", " where ", " who ", " how ", " which ", " why ", " do you know ", " you know what ",
                " you know how ", " is there ", " are there ", " can you ", " could you ", " tell me "].contains { t.contains($0) }
    }

    /// "Toby promised to send her the demo video": a promise the wearer made.
    static func isPromise(_ fact: String, by wearer: String) -> Bool {
        let f = fact.lowercased()
        return ["promised", "owes", "will send", "said he'd", "said she'd", "offered to"].contains { f.contains($0) }
            && (f.contains(wearer.lowercased()) || f.hasPrefix("wearer") || f.contains("you promised"))
    }

    /// A suggestion that asks them whether something in `promise` happened ("Did you catch the demo
    /// video?"), when the promise is the wearer's to keep.
    static func asksAbout(_ promise: String, in suggestion: String) -> Bool {
        let s = normalized(suggestion)
        guard ["did you", "have you", "did u", "you get", "you got", "you see", "you catch"].contains(where: s.hasPrefix)
                || s.hasPrefix("did") else { return false }
        let wanted = content(suggestion).subtracting(["did", "catch", "see", "get", "got", "send", "sent"])
        guard !wanted.isEmpty else { return false }
        return Double(wanted.intersection(content(promise)).count) / Double(wanted.count) >= 0.5
    }

    /// "Lens, what should I ask?", "what do I say", "give me something to talk about": the wearer
    /// wants a line to say, not an answer.
    static func asksForSuggestion(_ request: String) -> Bool {
        let r = " " + normalized(request) + " "
        return [" what should i ask", " what should i say", " what do i ask", " what do i say", " what can i ask",
                " what should i talk about", " what should we talk about", " what should i bring up",
                " give me a question", " give me something to", " suggest", " any ideas", " help me out "]
            .contains { r.contains($0) }
    }

    /// "Hey, I'm Priya" → "Priya". Only a capitalized word after a first-person introduction, so
    /// "I'm building" or "I'm really tired" never count.
    static func introducedName(in text: String) -> String? {
        let pattern = #"(?i:\b(?:i'm|i am|my name is|my name's|call me)\s+)([A-Z][a-z]+)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Two short notes that say the same thing ("paralegal for two years" vs "was a paralegal for
    /// two years"): most content words shared, either way round.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = content(a), y = content(b)
        guard !x.isEmpty, !y.isEmpty else { return normalized(a) == normalized(b) }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count)) >= 0.75
    }

    /// Complete sentences and whatever is still open after them. A sentence ends at . ? or !
    /// followed by a space; at the very end only ? and ! count, because a partial ending in "3."
    /// is usually on its way to "3.5".
    static func sentences(_ text: String) -> (closed: [String], open: String) {
        var closed: [String] = []
        var current = ""
        let characters = Array(text)
        for (i, character) in characters.enumerated() {
            current.append(character)
            guard ".?!".contains(character) else { continue }
            let last = i == characters.count - 1
            let ends = last ? character != "." : characters[i + 1].isWhitespace
            if ends {
                let sentence = current.trimmed
                if sentence.count > 1 { closed.append(sentence) }
                current = ""
            }
        }
        return (closed, current.trimmed)
    }

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
            .split(separator: " ").joined(separator: " ")
    }

    private static func content(_ text: String) -> Set<String> {
        Set(normalized(text).split(separator: " ").map(String.init).filter { $0.count > 2 && !stop.contains($0) })
    }

    private static let backchannel: Set<String> = [
        "yeah", "yea", "yes", "yep", "yup", "no", "nope", "ok", "okay", "right", "sure", "mhm", "mmhmm",
        "mm", "hmm", "uh", "um", "huh", "oh", "ah", "wow", "nice", "cool", "totally", "exactly", "true",
        "haha", "lol", "gotcha", "really", "interesting", "awesome", "great", "damn", "no", "way", "i", "see",
        "for", "real", "that", "makes", "sense", "same", "fair", "word", "agreed",
    ]

    private static let stop: Set<String> = [
        "the", "and", "you", "your", "yours", "what", "how", "why", "when", "where", "who", "did", "does",
        "was", "were", "are", "for", "that", "this", "with", "about", "from", "into", "have", "has", "had",
        "made", "make", "get", "got", "like", "its", "it's", "any", "there", "their", "they", "them",
        "been", "being", "would", "could", "should", "can", "will", "just", "really", "much", "very",
    ]
}

/// The conversation aid: transcript in, lens out. It does four things:
/// - Answer what's asked, from wherever the answer lives. The other person's questions stream an
///   answer mid-sentence (Answer.swift) from the conversation, what's known about them, or general
///   knowledge; a public fact the model can't give from memory says WEB and is looked up (Fetch.ai)
///   once the question closes; place, weather and calendar go to the device tools (Tools.swift).
///   The wearer asks the glasses anything with "Lens, …". Nothing is ever looked up about the
///   people talking.
/// - Define a term just said that the wearer wouldn't know (the coach, Coach.swift).
/// - Suggest what to say next, only when the wearer needs it: a lull, a request ("Lens, what
///   should I ask?"), or face ID recognising someone known (an opener from last time). The coach
///   writes the line for that moment, with everything known.
/// - Know who they're talking to: face ID and the CRM (`met`), their introduction, what they say.
/// Every model call sees the same context: the wearer, what's known about them, the conversation.
/// The Compositor (Lens.swift) decides what of all that is on the lens at any moment.
///
/// Pure Foundation, so the phone (Assistant) and the Mac (tools/live-mac.swift) run the same aid.
@MainActor @Observable final class Aid {
    struct Model: Equatable {
        var provider: Provider
        var key: String
        var model: String
    }

    struct Config {
        /// The wearer's first name, so the coach can tell who's who when it's said out loud.
        var wearer = "the wearer"
        /// Who the wearer is and what they know: keeps obvious terms from being defined, and gives
        /// suggestions their common ground.
        var background = ""
        /// Where the wearer is: "Cal Hacks 13.0, UC Berkeley, Oct 24-26 2026". "How many people are
        /// at this thing?" is about here; without this a search found a different hackathon.
        var situation = ""
        var answers: Model?
        var coach: Model?
        /// What to say next and openers when face ID recognises someone, if they should run on a
        /// different model from the coach. Unset (the default): the coach's model. Big models
        /// weren't worth it: the lines were no better and a second late.
        var suggest: Model?
        /// Used while `answers` or `coach` is rate-limited, or past `perMinute`.
        var backup: Model?
        /// Look-ups and actions on this device (places, weather, reminders, calendar).
        var toolbox: (any Toolbox)?
        /// The primary model's per-minute request cap, if the host has a small one (Cerebras
        /// gpt-oss-120b on the free tier: 5). Past it, lanes go straight to the backup instead of
        /// spending a round trip on a 429.
        var perMinute: Int?
        var researcher: (any Researcher)?
        /// Only explicit questions: an answer may be computed while they talk, but it goes up only
        /// once the sentence closes with "?". Statements that start like questions ("what you
        /// could do is…") got answers in a real conversation (2026-10-24).
        var explicitOnly = false
    }

    private(set) var lines: [Line] = []
    private(set) var turns: [Turn] = []
    private(set) var events: [Event] = []
    private(set) var lens = LensView()
    private(set) var them = Them()
    private(set) var roles = Roles()
    /// The turn still being spoken.
    private(set) var partial = ""
    /// Something worth surfacing about the lanes themselves (rate limits, failures).
    private(set) var status = ""
    /// Milliseconds per lane: "answer" = to first word, "coach" = per call, "research" = per lookup.
    private(set) var timings: [String: [Int]] = [:]

    /// Fires on every lens change; the glasses render it.
    @ObservationIgnored var onLens: ((LensView) -> Void)?
    /// Fires on every new event; the Mac tool prints it.
    @ObservationIgnored var onEvent: ((Event) -> Void)?
    /// Whether the wearer is the one talking right now, if the host can tell (nil: it can't).
    @ObservationIgnored var liveWearer: (() -> Bool?)?
    /// A speaker label's first name when the host knows who that is (face ID: "p:<id>"), so with
    /// three people the transcript says who said what instead of THEM twice.
    @ObservationIgnored var nameFor: ((String) -> String?)?

    @ObservationIgnored let config: Config

    init(config: Config) {
        self.config = config
    }

    var current: Turn? { turns.first }
    func tag(_ label: String?) -> String { roles.tag(label) }

    // MARK: - Input

    /// The turn in progress, cumulative ("How large is" … "How large is the moon?").
    func heard(partial text: String) {
        let text = text.trimmed
        guard !text.isEmpty, text != partial else { return }
        lastSpeech = Date()
        if partial.isEmpty { turnStarted = lastSpeech }
        if wanted == .lull { wanted = nil }   // someone's talking: the lull is over
        partial = text
        saying = "\(predictedTag()): \(text)"
        // Diarized turns alternate, so a turn in progress right after theirs is most likely ours.
        let mine = predictedWearer()
        compositor.hold(mine, at: Date())
        let (closed, open) = Talk.sentences(text)
        // A sentence closed inside the turn: to the answer lane that is an endpoint. Diarized turns
        // run until the speaker changes, so "Do you know X? Anyway, …" must not wait for "anyway".
        if closed.count > closedInTurn {
            for sentence in closed[closedInTurn...] where !command(sentence, mine: mine) {
                answerHeard(sentence, endpointed: true, mine: mine)
            }
            let newest = closed[closedInTurn...].joined(separator: " ")
            closedInTurn = closed.count
            // Coach each real sentence of theirs as it lands, so a definition is up while they're
            // still talking and the wearer is listening anyway.
            if !mine, newest.split(separator: " ").count >= 6, Date().timeIntervalSince(lastCoach) > 4 { coachSoon() }
        }
        if !open.isEmpty { answerHeard(open, endpointed: false, mine: mine) }
        publish()
        // Muse can take seconds to close a turn that ends in silence, and a lull is exactly that:
        // the clock starts at the last word, not at the closed line.
        watchForSilence()
    }

    /// A finished turn. `level` is its loudness in dB, for telling the wearer apart.
    func heard(line text: String, speaker: String?, level: Float? = nil) {
        let text = text.trimmed
        guard !text.isEmpty else { return }
        // Silence counts from the last word heard, not from when the recognizer closed the turn
        // (Muse took 5 s to close a "Wow." before a pause), so a late close neither restarts the
        // clock nor ends a lull. A typed line has no partials: it is speech now.
        if partial.isEmpty {
            lastSpeech = Date()
            if wanted == .lull { wanted = nil }
        }
        let started = turnStarted ?? Date()
        turnStarted = nil
        saying = "\(speakerTag(speaker)): \(text)"
        let mine = roles.isWearer(speaker)
        let (closed, open) = Talk.sentences(text)
        if closed.count > closedInTurn {
            for sentence in closed[closedInTurn...] where !command(sentence, mine: mine) {
                answerHeard(sentence, endpointed: true, mine: mine)
            }
        }
        if !open.isEmpty, !command(open, mine: mine) { answerHeard(open, endpointed: true, mine: mine) }
        partial = ""
        saying = ""   // it's a line now
        closedInTurn = 0
        compositor.hold(false, at: Date())

        if let speaker {
            let guessed = roles.wearer
            roles.heard(speaker, level: level)
            if !roles.sure, let wearer = roles.wearer, wearer != guessed {
                log(.roles, "You are probably speaker \(wearer)", detail: "your voice is louder at the mic; m if not")
            }
            // Someone introducing themselves settles who's who: our name means the wearer,
            // any other name means the other person, and is their name. Only an introduction names
            // them (or face ID): a name merely mentioned is usually someone else's.
            if let name = Talk.introducedName(in: text) {
                let ours = name.caseInsensitiveCompare(config.wearer) == .orderedSame
                if !roles.sure, ours {
                    roles.lock(speaker)
                    log(.roles, "You are speaker \(speaker)", detail: "you introduced yourself")
                } else if !roles.sure {
                    roles.lock(them: speaker)
                    log(.roles, "\(name) is speaker \(speaker)", detail: "they introduced themselves")
                }
                if !ours, !roles.isWearer(speaker), !them.recognised, them.name != name {
                    them.name = name
                    compositor.setHeader(name)
                    log(.learned, "Name: \(name)", detail: "they introduced themselves")
                }
            }
        }
        nextLine += 1
        lines.append(Line(id: nextLine, speaker: speaker, text: text, at: Date(), command: Tools.command(in: text) != nil))
        log(.line, text, detail: level.map { String(format: "%.0f dB", $0) } ?? "", speaker: speaker)

        // Whoever just said the pinned follow-up is the wearer, and it has been used. Never the
        // other person: the suggestion is built from their words, so they "echo" it all the time.
        if let followup = lens.followup, roles.tag(speaker) != "THEM", Talk.echoes(text, followup) {
            compositor.pin(nil, at: Date())
            log(.followup, "used", detail: followup)
            if let speaker, !roles.sure {
                roles.lock(speaker)
                log(.roles, "You are speaker \(speaker)", detail: "you said the suggestion")
            }
        } else if let followup = lens.followup, roles.isWearer(speaker), !Talk.isBackchannel(text), started > suggestedAt {
            // A suggestion is for the wearer's next turn. They've taken it; the moment passed. (A
            // turn begun before it went up and closed late doesn't count.)
            compositor.pin(nil, at: Date())
            log(.followup, "passed", detail: followup)
        }
        publish()

        if !roles.isWearer(speaker), !Talk.isBackchannel(text) { coachSoon() }
        watchForSilence()
    }

    /// The wearer says the most recent line was theirs.
    func lastLineWasMe() {
        guard let speaker = lines.last(where: { $0.speaker != nil })?.speaker else { return }
        markWearer(speaker)
    }

    /// The host already knows which label is the wearer (it resolves speakers itself): lock it
    /// quietly, so loudness and introductions here don't second-guess it.
    func assume(wearer label: String) {
        roles.lock(label)
    }

    func markWearer(_ label: String) {
        roles.lock(label)
        log(.roles, "You are speaker \(label)", detail: "you said so")
    }

    /// Face ID says who the other person is; `facts` are their profile and what the CRM keeps
    /// (last conversation, promises both ways). Replaces the profile when it's someone new.
    func met(name: String, label: String?, facts: [String]) {
        guard !(them.recognised && them.name == name) else { return }
        // In a group the focus moves between people; whoever it leaves stays known to every lane.
        let before = others.first { $0.name == name }
        if them.recognised { others.insert(them, at: 0) }
        others = Array(others.filter { $0.name != name }.prefix(4))
        them = Them(name: name, label: label, facts: facts, recognised: true)
        log(.learned, "Talking to \(name)", detail: "face ID")
        compositor.setHeader(name)
        publish()
        // Someone known, met for the first time this conversation: the moment for an opener from
        // what we know (last time, a promise). Not again each time the focus comes back to them.
        if !them.facts.isEmpty, before == nil { offer(.recognised) }
    }

    /// Everyone else face ID named in this conversation, most recent first.
    private(set) var others: [Them] = []

    /// Start over for a new conversation.
    func reset() {
        answerTask?.cancel(); coachTask?.cancel(); lookupTask?.cancel(); tickTask?.cancel(); silenceTask?.cancel()
        lines = []; turns = []; events = []; them = Them(); others = []; ideas = []; roles = Roles(); partial = ""; status = ""
        compositor.clear(); defined = []; asked = []; answeredAt = .distantPast; firedText = ""; generation += 1
        coachPending = false; coachBlockedUntil = nil; closedInTurn = 0
        wanted = nil; suggested = []; suggestedAt = .distantPast; turnStarted = nil; lastCommand = nil; saying = ""
        publish()
    }

    // MARK: - Answers: the fast lane
    //
    // The whole design is about hiding latency inside the question rather than after it. A
    // question takes a human one to three seconds to say, and we know what it is well before the
    // last word: as soon as four words of a question clause exist we fire a speculative request on
    // the partial transcript, so the model's time-to-first-token overlaps the rest of the sentence.
    // Guards: refire only on real growth, at most `maxFires` times; ignore superseded fires
    // (generation counter); the model returns SKIP for anything personal, social or rhetorical,
    // and WEB for a public fact it can't give from memory, which is looked up once the question
    // closes (never mid-sentence: half a question makes a bad search).

    private static let refireGrowth = 2
    private static let maxFires = 3
    private static let refireInterval: TimeInterval = 0.4

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var firedText = ""
    @ObservationIgnored private var lastFireAt = Date.distantPast
    @ObservationIgnored private var answerTask: Task<Void, Never>?
    @ObservationIgnored private var answersBlockedUntil: Date?
    @ObservationIgnored private var closedInTurn = 0
    @ObservationIgnored private var nextCard = 0

    /// `mine`: the wearer is the one asking. Then the other person is about to answer, and an
    /// answer on the lens only competes with them (the judge, on "how long does that take":
    /// "encouraging Toby to look away from the person actually answering").
    private func answerHeard(_ text: String, endpointed: Bool, mine: Bool) {
        guard config.answers != nil else { return }
        // Where, weather, my calendar: worth answering whoever asked, and only a tool can.
        let toolish = config.toolbox != nil && Tools.wants(text)
        if mine, roles.known, !toolish {
            if endpointed { commit(nil) }
            return
        }
        guard let candidate = QuestionGate.candidate(in: text) else {
            if endpointed { commit(nil) }
            return
        }
        if config.explicitOnly, endpointed, !text.trimmed.hasSuffix("?") {
            abandon()
            return
        }
        if toolish {
            // Never speculatively: "how far is the nearest" would search before "Target" is said.
            if endpointed { toolRound(candidate.text, command: false) }
            return
        }
        if endpointed {
            commit(candidate)
            return
        }
        guard candidate.confidence == .strong else { return }
        if firedText.isEmpty || shouldRefire(candidate.text) { fire(candidate.text) }
    }

    private func shouldRefire(_ text: String) -> Bool {
        guard let turn = turns.first, turn.fires < Self.maxFires, text != firedText else { return false }
        guard Date().timeIntervalSince(lastFireAt) > Self.refireInterval else { return false }
        let grew = words(text) - words(firedText)
        // It needs the web: nothing to gain from asking again before the question closes.
        if turn.lookup { return false }
        // The model already told us our guess was too fragmentary to answer; any new word is a
        // reason to try again.
        if turn.state == .skipped { return grew >= 1 }
        // Growth that merely extends what we asked is cheap to ignore until it is substantial; a
        // question that changed shape entirely means we guessed wrong and should start over.
        if text.hasPrefix(firedText) { return grew >= Self.refireGrowth }
        return grew >= 1 || !firedText.hasPrefix(text)
    }

    /// The sentence ended. Lock in the real question and make sure that is what we answered.
    private func commit(_ candidate: Candidate?) {
        defer { firedText = "" }
        guard let candidate else {
            // Not a question after all, or they trailed off. Abandon a speculation that has nothing
            // to show; leave a partial answer up, since they did ask for it.
            if !firedText.isEmpty, let turn = turns.first, turn.live, turn.answer.isEmpty {
                answerTask?.cancel()
                generation += 1
                turns[0].state = .skipped
                render()
            }
            return
        }
        guard var turn = turns.first, !firedText.isEmpty else {
            fire(candidate.text, committed: true)
            return
        }
        turn.committedAt = Date()
        turns[0] = turn
        let grew = words(candidate.text) - words(firedText)
        // The model said this needs the web. Look up the whole question, unless it grew enough that
        // the verdict may have changed ("what's the latest" … "you've stayed up coding?").
        if turn.lookup, grew < Self.refireGrowth {
            lookUp(candidate.text)
            return
        }
        let refused: Bool
        switch turn.state {
        case .skipped, .failed: refused = true
        default: refused = false
        }
        // Substantially more question than we guessed, or a guess the model refused: ask properly.
        // Otherwise let the in-flight answer stand — one trailing noun almost never changes it.
        if candidate.text != firedText, grew >= Self.refireGrowth || refused {
            fire(candidate.text, committed: true)
        } else {
            turns[0].question = candidate.text
            render()
        }
    }

    private func fire(_ question: String, committed: Bool = false) {
        guard let answers = model(config.answers, blockedUntil: answersBlockedUntil) else { return }
        answerTask?.cancel()
        generation += 1
        let generation = self.generation
        firedText = question
        lastFireAt = Date()

        if var turn = turns.first, turn.live {
            turn.question = question
            turn.fires += 1
            if committed { turn.committedAt = Date() }
            turns[0] = turn
        } else {
            nextCard += 1
            var turn = Turn(card: nextCard, question: question)
            turn.fires = 1
            if committed { turn.committedAt = Date() }
            turns.insert(turn, at: 0)
            if turns.count > 30 { turns.removeLast() }
        }

        // The local tier (time, date, arithmetic) can finish before the network one starts.
        if let instant = Answerer.local(question) {
            update(generation) { $0.answer = instant; $0.state = .done; $0.shownAt = Date() }
            render()
            log(.answer, instant, detail: "\(question) · local")
            return
        }

        render()
        let context = self.context(last: 6)
        let fired = Date()
        let backup = config.backup
        answerTask = Task { [weak self] in
            do {
                var any = false
                var first: Date?
                var using = answers
                while true {
                    do {
                        for try await partial in Answerer.stream(question, context: context, provider: using.provider,
                                                                 key: using.key, model: using.model) {
                            guard !Task.isCancelled else { return }
                            any = true
                            if first == nil { first = Date() }
                            self?.update(generation) {
                                if $0.shownAt == nil { $0.shownAt = Date() }
                                $0.answer = partial
                                $0.state = .answering
                            }
                            self?.render()
                        }
                        break
                    } catch AnswerError.http(let code) where code == 429 && !any {
                        // Rate-limited before a word arrived: this answer and the next minute's go to the backup.
                        guard let backup, backup != using else { throw AnswerError.http(code) }
                        self?.answersBlockedUntil = Date().addingTimeInterval(60)
                        self?.log(.status, "Answers rate-limited on \(using.provider.rawValue); using \(backup.provider.rawValue) \(backup.model)")
                        using = backup
                    }
                }
                guard !Task.isCancelled, let self, generation == self.generation else { return }
                self.update(generation) { $0.state = any ? .done : .skipped }
                self.render()
                if any, let turn = self.turns.first, let first {
                    let ms = Int((first.timeIntervalSince(fired) * 1000).rounded())
                    self.timings["answer", default: []].append(ms)
                    self.log(.answer, turn.answer, detail: "\(turn.question) · first word \(ms) ms · \(using.model)")
                }
            } catch AnswerError.lookup {
                guard !Task.isCancelled, let self, generation == self.generation else { return }
                self.update(generation) { $0.state = .skipped; $0.lookup = true }
                self.render()
                // Already the whole question: look it up now. Mid-sentence, commit() will.
                if let turn = self.turns.first, turn.committedAt != nil { self.lookUp(turn.question) }
            } catch {
                guard !Task.isCancelled else { return }
                self?.update(generation) { $0.state = .failed(error.localizedDescription) }
                self?.render()
                self?.log(.status, "Answer failed: \(error.localizedDescription)")
            }
        }
    }

    /// Only touch the turn if it still belongs to the fire that is talking.
    private func update(_ generation: Int, _ change: (inout Turn) -> Void) {
        guard generation == self.generation, var turn = turns.first else { return }
        change(&turn)
        turns[0] = turn
    }

    /// Not a question after all: drop the speculation, even one that already has an answer.
    private func abandon() {
        defer { firedText = "" }
        guard !firedText.isEmpty, let turn = turns.first, turn.committedAt == nil, turn.state != .skipped else { return }
        answerTask?.cancel()
        generation += 1
        turns[0].state = .skipped
        render()
    }

    private func render() {
        guard let turn = turns.first else { return }
        let now = Date()
        // Explicit questions only: hold the answer until the question has closed.
        if config.explicitOnly, turn.committedAt == nil, turn.live || turn.state == .done { return }
        switch turn.state {
        case .thinking, .answering, .done:
            // Nothing goes up until there is an answer: a "…" for every question-shaped phrase was
            // half of everything on the lens, and most of those turned out to be SKIPs.
            guard !turn.answer.isEmpty else { return }
            answeredAt = now
            answeredText = turn.question + " " + turn.answer
            compositor.show(Card(kind: .answer, title: turn.answer, detail: Self.echo(turn.question),
                                 live: turn.state != .done, id: turn.card), at: now)
        case .skipped, .failed:
            compositor.remove(id: turn.card, kind: .answer, at: now)
        }
        publish()
    }

    /// The lens is small: echo just enough of the question to make the answer legible.
    private static func echo(_ question: String) -> String {
        let words = question.split(separator: " ")
        return words.count > 7 ? words.prefix(7).joined(separator: " ") + "\u{2026}" : question
    }

    private func words(_ s: String) -> Int { s.split(separator: " ").count }

    // MARK: - Tools: things only the device knows or can do

    @ObservationIgnored private var lastCommand: (text: String, at: Date)?

    /// "Lens, …" from the wearer (from anyone, while we don't know who that is): "what should I
    /// ask?" gets a suggestion, anything else goes to the tool model with the whole context. True
    /// when `sentence` was a command, handled or deliberately dropped.
    private func command(_ sentence: String, mine: Bool) -> Bool {
        guard config.toolbox != nil, let request = Tools.command(in: sentence) else { return false }
        guard mine || !roles.known else { return true }   // the other person saying "lens" isn't asking us
        // The same sentence arrives twice, as a partial and as the finished line; a few seconds
        // later it's a new request.
        if let last = lastCommand, Talk.normalized(request) == Talk.normalized(last.text),
           Date().timeIntervalSince(last.at) < 8 { return true }
        lastCommand = (request, Date())
        if Talk.asksForSuggestion(request) {
            suggestNow()
        } else {
            toolRound(request, command: true)
        }
        return true
    }

    /// One request that may need a tool: the model answers, skips, or names a tool; the device
    /// runs it; the result goes up as an answer card as it is, no second model call. A command
    /// shows what it's doing if the tool takes a moment; an overheard question just shows the result.
    private func toolRound(_ request: String, command: Bool) {
        guard let toolbox = config.toolbox, let primary = model(config.answers, blockedUntil: answersBlockedUntil) else { return }
        nextCard += 1
        let card = nextCard, echo = Self.echo(request), started = Date()
        if let instant = Answerer.local(request) {
            compositor.show(Card(kind: .answer, title: instant, detail: echo, id: card, icon: "clock"), at: started)
            log(.answer, instant, detail: "\(request) · local")
            publish()
            return
        }
        toolbox.prefetch(request)   // the obvious search starts while the model decides
        // "her company", "what did she say about hiring", "that place": answered or resolved from
        // what we know and the conversation.
        let context = self.context(last: 30)
        let backup = config.backup
        // Each request runs on its own card: their question must not cancel the wearer's command.
        Task { [weak self] in
            var used = primary
            do {
                var decision: Tools.Decision
                do {
                    decision = try await Tools.decide(request, context: context, toolbox: toolbox, provider: primary.provider,
                                                      key: primary.key, model: primary.model)
                } catch LLM.Failure.rateLimited(let wait) {
                    guard let backup, backup != primary else { throw LLM.Failure.rateLimited(retryAfter: wait) }
                    self?.answersBlockedUntil = Date().addingTimeInterval(60)
                    used = backup
                    decision = try await Tools.decide(request, context: context, toolbox: toolbox, provider: backup.provider,
                                                      key: backup.key, model: backup.model)
                }
                guard !Task.isCancelled, let self else { return }
                switch decision {
                case .skip:
                    if command { self.put(Card(kind: .answer, title: "Not sure", detail: echo, id: card)) }
                    return
                case .answer(let text):
                    self.put(Card(kind: .answer, title: text, detail: echo, id: card))
                    self.log(.answer, text, detail: "\(request) · \(self.ms(since: started)) ms · \(used.model)")
                case .call(let name, let arguments):
                    // A slow one gets a working row with a countdown, not the card slot: a quick
                    // answer or a definition can still show while it runs.
                    let ack = command ? Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled, let self else { return }
                        self.compositor.startWork(id: card, label: toolbox.working(name, arguments: arguments), at: Date())
                        self.publish()
                    } : nil
                    defer { ack?.cancel(); self.compositor.endWork(id: card); self.publish() }
                    let result = try await toolbox.run(name, arguments: arguments)
                    ack?.cancel()
                    guard !Task.isCancelled else { return }
                    self.compositor.endWork(id: card)
                    // Research that found nothing ("Not yet announced") isn't worth a glance.
                    guard !result.title.isEmpty else {
                        if command { self.put(Card(kind: .answer, title: "Couldn't find that", detail: echo, id: card)) }
                        self.log(.lookup, request, detail: "no answer found")
                        return
                    }
                    self.put(Card(kind: .answer, title: result.title, detail: result.detail, id: card, icon: result.icon))
                    self.log(.answer, result.title, detail: "\(request) · \(name) · \(self.ms(since: started)) ms · \(used.model)")
                }
                self.timings["tool", default: []].append(self.ms(since: started))
            } catch {
                guard !Task.isCancelled else { return }
                if command { self?.put(Card(kind: .answer, title: "Couldn't do that", detail: echo, id: card, icon: "exclamationCircle")) }
                self?.log(.status, "Tool failed: \(error.localizedDescription)")
            }
        }
    }

    private func put(_ card: Card) {
        if card.kind == .answer {
            answeredAt = Date()
            answeredText = card.title + " " + card.detail
        }
        compositor.show(card, at: Date())
        publish()
    }

    private func ms(since date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1000) }

    // MARK: - Coach: the slow lane

    @ObservationIgnored private var coachTask: Task<Void, Never>?
    @ObservationIgnored private var coachPending = false
    @ObservationIgnored private var coachBlockedUntil: Date?
    @ObservationIgnored private var lastCoach = Date.distantPast
    @ObservationIgnored private var lastSpeech = Date()
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var defined: [String] = []
    /// Requests the coach rebuilt, so one garbled question is asked once.
    @ObservationIgnored private var asked: [String] = []
    /// When an answer last went up (any lane), so a rebuilt request doesn't repeat one, and what it
    /// was about, so a definition doesn't either.
    @ObservationIgnored private var answeredAt = Date.distantPast
    @ObservationIgnored private var answeredText = ""

    /// One call at a time; anything heard meanwhile folds into one more call right after.
    private func coachSoon() {
        guard config.coach != nil else { return }
        if coachTask != nil {
            coachPending = true
            return
        }
        let moment = wanted
        // Spend a capped primary on what the wearer will see: a suggestion for this moment gets it
        // (gpt-oss writes far better lines than the backup); the background calls after each
        // sentence (a definition) go to the backup. Uncapped, everything uses the primary.
        let pick = moment != nil && config.suggest != nil ? config.suggest
            : moment == nil && config.perMinute != nil && config.backup != nil
            ? config.backup : model(config.coach, blockedUntil: coachBlockedUntil, reserve: moment == nil ? 3 : 0)
        guard let coach = pick else {
            coachPending = true   // rate-limited with no backup: blockCoach retries when it lifts
            return
        }
        let input = coachInput(for: moment)
        let backup = config.backup
        lastCoach = Date()
        coachTask = Task { [weak self] in
            let started = Date()
            do {
                let advice: Coach.Advice
                do {
                    advice = try await Coach.ask(input, provider: coach.provider, key: coach.key, model: coach.model)
                } catch LLM.Failure.rateLimited(let wait) {
                    // The primary's limit ran out: block it for a while and ask the backup right away.
                    self?.blockCoach(for: wait, falling: backup != nil && backup != coach)
                    guard let backup, backup != coach else { throw LLM.Failure.rateLimited(retryAfter: wait) }
                    advice = try await Coach.ask(input, provider: backup.provider, key: backup.key, model: backup.model)
                }
                self?.timings["coach", default: []].append(Int(Date().timeIntervalSince(started) * 1000))
                self?.apply(advice, for: moment)
            } catch LLM.Failure.rateLimited {
                // Already blocked above; the retry fires when the block lifts.
            } catch {
                self?.log(.status, "Coach failed: \(error.localizedDescription)")
            }
            self?.coachDone()
        }
    }

    /// The configured model, or the backup while it is rate-limited or out of per-minute calls;
    /// nil when neither can be used. `reserve` leaves that many of the minute's calls for the
    /// answer lane, which is the one that can't wait.
    private func model(_ primary: Model?, blockedUntil: Date?, reserve: Int = 0) -> Model? {
        guard let primary else { return nil }
        if let blockedUntil, blockedUntil > Date() { return config.backup }
        guard let cap = config.perMinute, primary != config.backup, config.backup != nil else { return primary }
        let now = Date()
        calls[primary.model, default: []].removeAll { now.timeIntervalSince($0) > 60 }
        guard calls[primary.model, default: []].count < cap - reserve else { return config.backup }
        calls[primary.model, default: []].append(now)
        return primary
    }

    @ObservationIgnored private var calls: [String: [Date]] = [:]

    private func coachDone() {
        coachTask = nil
        if coachPending {
            coachPending = false
            coachSoon()
        }
    }

    private func blockCoach(for wait: TimeInterval, falling: Bool) {
        coachBlockedUntil = Date().addingTimeInterval(wait)
        if falling, let backup = config.backup {
            log(.status, "Coach rate-limited on \(config.coach?.provider.rawValue ?? "?") for \(Int(wait.rounded())) s; using \(backup.provider.rawValue) \(backup.model)")
            return
        }
        coachPending = true
        status = "Coach rate-limited for \(Int(wait.rounded())) s"
        log(.status, status)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, self.coachPending else { return }
            self.status = ""
            self.coachPending = false
            self.coachSoon()
        }
    }

    private func coachInput(for moment: Moment?) -> Coach.Input {
        // Networking conversations are short; the whole of one fits, so nothing said early is lost.
        var transcript = transcriptLines(last: 30)
        if !partial.isEmpty { transcript.append("\(predictedTag()) (still talking): \(partial)") }
        // The coach writes a suggestion only for a moment, and for that moment.
        let why: String? = switch moment {
        case .lull: "a silence; revive the best thread"
        case .asked: "the wearer asks what to say next"
        case .recognised: "face ID just recognised THEM; pick up where you left off last time"
        case nil: nil
        }
        return Coach.Input(wearer: config.wearer, background: config.background, situation: config.situation, known: known,
                           defined: defined, suggested: suggested, moment: why, transcript: transcript)
    }

    /// `moment`: the moment this call was asked to write a suggestion for, if any.
    private func apply(_ advice: Coach.Advice, for moment: Moment?) {
        let now = Date()
        let recent = Talk.normalized((lines.suffix(2).map(\.text) + [partial]).joined(separator: " "))
        // Only a term just said, of real substance, that the coach is sure of: "LO — likely
        // misheard LLM" (it was Elo) is worse than nothing.
        let unsure = ["misheard", "likely", "probably", "possibly", "unclear", "perhaps"]
        // Not a term an answer card just covered: "what's Cohen's kappa?" got an answer and then the
        // same thing again as a definition.
        let answered = now.timeIntervalSince(answeredAt) < 15 ? Talk.normalized(answeredText) : ""
        for term in advice.define where !defined.contains(where: { Talk.mentioned($0, in: Talk.normalized(term.term + " " + term.meaning)) })
            && term.term.count >= 3 && Talk.mentioned(term.term, in: recent) && !Talk.mentioned(term.term, in: answered)
            && !unsure.contains(where: term.meaning.lowercased().contains) {
            defined.append(term.term)
            nextCard += 1
            compositor.show(Card(kind: .definition, title: term.term, detail: term.meaning, id: nextCard), at: now)
            log(.define, term.term, detail: term.meaning)
        }
        // The recognizer garbled a request the gate or the answer model let go: the coach's clean
        // version goes to the tool model (answer, device tool or Fetch), unless something already
        // answered this turn.
        // Only if they asked something: "we just raised a seed around" was rebuilt into "How much
        // did the company raise?" and answered with a made-up number about their own company.
        let theirs = (lines.last { !roles.isWearer($0.speaker) }?.text ?? "") + " " + (predictedWearer() ? "" : partial)
        if let ask = advice.ask, Talk.asks(theirs), Date().timeIntervalSince(answeredAt) > 8, lookupTask == nil,
           turns.first?.live != true, !asked.contains(where: { Talk.same($0, ask) }) {
            asked.append(ask)
            answeredAt = now
            log(.lookup, ask, detail: "rebuilt from what was heard")
            toolRound(ask, command: false)
        }
        // Shown only while its moment lasts: speech ends a lull (`wanted` is cleared), so a line that
        // arrives after they started talking again stays off the lens.
        if let moment, wanted != nil {
            // A lull is optional: a line the coach itself rates as one anyone could say isn't worth
            // breaking the silence for. Asked for, or a face just recognised, the best one goes up.
            let good = moment != .lull || (advice.score ?? 3) >= 3
            // The best that passes the checks; a runner-up when the best asks them about the wearer's
            // own promise ("Did you catch the demo video?" when Toby owes it) or was already said.
            let promises = (them.facts + others.flatMap(\.facts)).filter { Talk.isPromise($0, by: config.wearer) }
            let pick = ([advice.suggest].compactMap { $0 } + advice.alternatives.map(\.say))
                .first { line in usable(line) && !promises.contains { Talk.asksAbout($0, in: line) } }
            if let text = pick, good { suggest(text) } else if wanted == moment { wanted = nil }
        }
        // The runners-up wait for the next lull, which then needs no call at all.
        if moment != nil {
            // Only ones good enough to show in a lull on their own (score 3+).
            let fresh = advice.alternatives.filter { ($0.score ?? 3) >= 3 }.map(\.say)
                .filter { text in usable(text) && !ideas.contains { Talk.same($0.text, text) } }
            ideas = Array((fresh.map { (text: $0, at: now, line: lines.count) } + ideas).prefix(4))
        }
        if status.hasPrefix("Coach") { status = "" }
        publish()
    }

    // MARK: - Suggestions: what to say next, only when it's needed
    //
    // When is decided here, from signals that can't be wrong about timing: a silence after a line,
    // the wearer asking ("Lens, what should I ask?", a pinch, `s` on the Mac), or face ID
    // recognising someone known. Only then is the coach asked for a line, written for that moment
    // with everything known. Mid-conversation a suggestion only competes with the person talking;
    // in a lull it's the one thing that helps.

    enum Moment { case lull, asked, recognised }

    /// A moment waiting for its suggestion. Speech ends a lull; a request or a face stands.
    @ObservationIgnored private var wanted: Moment?
    @ObservationIgnored private var suggestedAt = Date.distantPast
    /// When the turn in progress began (its first partial).
    @ObservationIgnored private var turnStarted: Date?
    /// Everything shown so far, so none comes round twice.
    @ObservationIgnored private var suggested: [String] = []

    /// Seconds of quiet after a line that count as a lull. Under three seconds is someone thinking.
    private static let lull: TimeInterval = 3

    /// The wearer asks what to say: a pinch on the glasses, "Lens, what should I ask?", `s` on the Mac.
    func suggestNow() {
        offer(.asked)
    }

    private func offer(_ moment: Moment) {
        guard config.coach != nil else { return }
        wanted = moment
        // A line written at the last moment that still fits: up now, instead of a model call later.
        if moment != .recognised, let idea = nextIdea() {
            log(.followup, "from the last batch", detail: idea)
            suggest(idea)
            return
        }
        coachSoon()
    }

    /// The coach's runners-up from the last suggestion it wrote, with when and how far into the
    /// conversation, so a stale one is never shown.
    @ObservationIgnored private var ideas: [(text: String, at: Date, line: Int)] = []

    /// The best idea still current: under 90 s old, never said or shown, and nothing new from them
    /// since it was written. Once they've said something, the newest thing beats an old thread
    /// ("we're hiring" lost to a queued "What base models do you test?").
    private func nextIdea() -> String? {
        let now = Date()
        let theirs = lines.lastIndex { !roles.isWearer($0.speaker) && !Talk.isBackchannel($0.text) }.map { $0 + 1 } ?? 0
        ideas.removeAll { now.timeIntervalSince($0.at) > 90 || theirs > $0.line || !usable($0.text) }
        return ideas.isEmpty ? nil : ideas.removeFirst().text
    }

    private func suggest(_ text: String) {
        wanted = nil
        suggestedAt = Date()
        suggested.append(text)
        compositor.pin(text, at: Date())
        log(.followup, text)
        publish()
    }

    /// A line to say to them, short, new, and not already said: a reply on the wearer's behalf
    /// ("No, this is my first hackathon") claims things the aid can't know.
    private func usable(_ text: String) -> Bool {
        text.split(separator: " ").count <= 14 && !Talk.speaksForWearer(text)
            && !suggested.contains { Talk.same($0, text) }
            && !lines.suffix(8).contains { Talk.echoes($0.text, text) }
    }

    /// After every word: if nobody speaks for `lull` seconds, that's the moment for a suggestion.
    /// Not when they just asked the wearer something (the wearer is thinking of an answer, not a
    /// question), not after "Lens, …" (they're reading the answer), not while one is already up,
    /// and not before we know who's who.
    private func watchForSilence() {
        silenceTask?.cancel()
        let wait = max(0.2, Self.lull - Date().timeIntervalSince(lastSpeech))
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, Date().timeIntervalSince(self.lastSpeech) >= Self.lull - 0.2,
                  self.lens.followup == nil, self.roles.known else { return }
            // The last thing said, counting a turn the recognizer hasn't closed yet.
            let open = !self.partial.isEmpty
            let last = open ? self.partial : self.lines.last?.text ?? ""
            let theirs = open ? self.predictedTag() == "THEM" : self.roles.tag(self.lines.last?.speaker) == "THEM"
            guard !last.isEmpty, Tools.command(in: last) == nil, !(theirs && last.contains("?")) else { return }
            self.compositor.hold(false, at: Date())   // three seconds of quiet: nobody is talking
            self.offer(.lull)
        }
    }

    // MARK: - Lookups: public facts that need the web

    @ObservationIgnored private var lookupTask: Task<Void, Never>?

    /// The answer model said this needs the web. The researcher (Fetch.ai ASI:One) looks it up and
    /// a fast model cuts the finding to a card. Only the question and the last few lines go out, to
    /// resolve "it" or "that bill"; what's known about the person never does: the web is for public
    /// things.
    private func lookUp(_ question: String) {
        guard let researcher = config.researcher else {
            log(.lookup, question, detail: "needs the web; research is off")
            return
        }
        guard lookupTask == nil else {
            log(.lookup, question, detail: "skipped, another lookup is running")
            return
        }
        log(.lookup, question, detail: "looking up with \(researcher.name)")
        answeredAt = Date()
        nextCard += 1
        let card = nextCard, started = Date()
        compositor.startWork(id: card, label: config.toolbox?.working("research", arguments: "{}") ?? "Looking it up", at: started)
        publish()
        // Where they are resolves "this thing" and "here"; who they are never goes out.
        let context = (config.situation.isEmpty ? "" : "Where: \(config.situation)\n") + transcript(last: 4)
            + (saying.isEmpty ? "" : "\n" + saying)
        let condenser = (config.perMinute != nil ? config.backup : nil) ?? config.answers ?? config.backup
        lookupTask = Task { [weak self] in
            do {
                let finding = try await researcher.research(question, context: context)
                var result = ToolResult(title: String(finding.prefix(60)), detail: "", icon: "starCircleTriangleAi")
                if let condenser {
                    result = try await Tools.card(from: finding, about: question, provider: condenser.provider,
                                                  key: condenser.key, model: condenser.model)
                }
                guard let self else { return }
                self.compositor.endWork(id: card)
                guard !result.title.isEmpty else {
                    self.log(.lookup, question, detail: "no answer found")
                    self.publish()
                    self.lookupTask = nil
                    return
                }
                self.put(Card(kind: .answer, title: result.title, detail: result.detail, id: card, icon: result.icon))
                let ms = self.ms(since: started)
                self.timings["research", default: []].append(ms)
                self.log(.research, result.title, detail: "\(result.detail) · \(question) · \(ms) ms")
            } catch {
                self?.log(.status, "Lookup failed: \(error.localizedDescription)")
            }
            self?.compositor.endWork(id: card)
            self?.publish()
            self?.lookupTask = nil
        }
    }

    // MARK: - Lens

    @ObservationIgnored private var compositor = Compositor()
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    private func publish() {
        let view = compositor.view
        if view != lens {
            lens = view
            onLens?(view)
        }
        tickTask?.cancel()
        guard let deadline = compositor.nextDeadline else { return }
        tickTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.compositor.tick(at: Date())
            self.publish()
        }
    }

    // MARK: - Transcript

    private func transcriptLines(last n: Int) -> [String] {
        lines.filter { !$0.command }.suffix(n).map { "\(speakerTag($0.speaker)): \($0.text.count > 400 ? String($0.text.prefix(400)) + "…" : $0.text)" }
    }

    /// ME, the speaker's first name when the host knows them, else THEM.
    private func speakerTag(_ label: String?) -> String {
        let tag = roles.tag(label)
        guard tag == "THEM", let label, let name = nameFor?(label) else { return tag }
        return name
    }

    private func transcript(last n: Int) -> String {
        transcriptLines(last: n).joined(separator: "\n")
    }

    /// The turn being handled, tagged. The sentence before a question often says what it's about:
    /// "Did you see Figure raised again? Do you know how much they raised?"
    @ObservationIgnored private var saying = ""

    /// What a model needs to make sense of a question: what's known about them, the last few lines,
    /// and the turn the question is in.
    private func context(last n: Int) -> String {
        (config.situation.isEmpty ? "" : "Where: \(config.situation)\n") + (known.isEmpty ? "" : "About them: \(known)\n")
            + transcript(last: n) + (saying.isEmpty ? "" : "\n" + saying)
    }

    /// What's known about whoever the wearer is talking to, then anyone else in the conversation.
    private var known: String {
        let rest = others.map(\.summary).filter { !$0.isEmpty }
        return ([them.summary].filter { !$0.isEmpty } + (rest.isEmpty ? [] : ["Also in this conversation: " + rest.joined(separator: " | ")]))
            .joined(separator: "\n")
    }

    /// Diarized turns alternate, so the turn in progress is most likely the other speaker's.
    private func predictedTag() -> String {
        if let live = liveWearer?() { return live ? "ME" : "THEM" }
        guard let previous = lines.last?.speaker else { return "?" }
        if roles.known { return previous == roles.wearer ? "THEM" : "ME" }
        return previous == "A" ? "B" : "A"
    }

    private func predictedWearer() -> Bool {
        // The host can hear the wearer directly (the glasses' own mic); alternation is only a guess,
        // and a wrong one with three people: after Avi, Mira's question isn't the wearer's.
        if let live = liveWearer?() { return live }
        guard roles.known, let previous = lines.last?.speaker else { return false }
        return previous != roles.wearer
    }

    // MARK: -

    @ObservationIgnored private var nextLine = 0
    @ObservationIgnored private var nextEvent = 0

    private func log(_ kind: Event.Kind, _ text: String, detail: String = "", speaker: String? = nil) {
        nextEvent += 1
        let event = Event(id: nextEvent, kind: kind, text: text, detail: detail, speaker: speaker, at: Date())
        events.append(event)
        if events.count > 400 { events.removeFirst(events.count - 400) }
        onEvent?(event)
    }
}

extension Aid.Config {
    /// Lanes from Info.plist keys, which Secrets.xcconfig fills at build time. A lane without a
    /// key is off. The coach defaults to the answer provider, research to off.
    static func fromBundle(wearer: String) -> Aid.Config {
        func value(_ key: String) -> String? {
            let v = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmed ?? ""
            return v.isEmpty || v.hasPrefix("$(") ? nil : v
        }
        let answerProvider = Provider(rawValue: value("AnswerProvider")?.lowercased() ?? "") ?? .groq
        let answerKey = value("AnswerAPIKey")
        let coachProvider = Provider(rawValue: value("CoachProvider")?.lowercased() ?? "") ?? answerProvider
        let coachKey = value("CoachAPIKey") ?? (coachProvider == answerProvider ? answerKey : nil)

        let backupProvider = Provider(rawValue: value("BackupProvider")?.lowercased() ?? "") ?? .openai
        let backup = value("BackupAPIKey").map { Aid.Model(provider: backupProvider, key: $0, model: value("BackupModel") ?? backupProvider.model) }
        let answers = answerKey.map { Aid.Model(provider: answerProvider, key: $0, model: value("AnswerModel") ?? answerProvider.model) }
        // Cutting a finding down to a card wants the fastest model with calls to spare: the answer
        // model when it's uncapped (qwen on Cerebras: 450/min), else the backup.
        let capped = value("AnswerPerMinute").flatMap { Int($0) } != nil
        let condenser = ((capped ? backup : nil) ?? answers ?? backup).map { (provider: $0.provider, key: $0.key, model: $0.model) }

        // Research (tier 3): Exa (fast search, condensed by the backup), Fetch.ai ASI:One, or
        // OpenAI or Groq web search.
        var researcher: (any Researcher)?
        let researchKey = value("ResearchAPIKey")
        switch value("ResearchProvider")?.lowercased() {
        case "exa":
            if let key = researchKey { researcher = Exa(key: key, type: value("ResearchModel") ?? "instant", resolver: condenser) }
        case "asi1", "fetch", "fetchai":
            if let key = researchKey { researcher = ASIOne(key: key, model: value("ResearchModel") ?? "asi1") }
        case "openai":
            if let key = researchKey { researcher = WebResearcher.openai(key: key) }
        case "groq":
            if let key = researchKey ?? (answerProvider == .groq ? answerKey : nil) { researcher = WebResearcher.groq(key: key) }
        default:
            break
        }
        let suggestProvider = Provider(rawValue: value("SuggestProvider")?.lowercased() ?? "")
        let suggest = suggestProvider.flatMap { provider in
            value("SuggestAPIKey").map { Aid.Model(provider: provider, key: $0, model: value("SuggestModel") ?? provider.model) }
        }
        // "37.7880,-122.4075": pretend to be there instead of asking Core Location (testing, or a
        // Mac command-line tool that can't get a fix).
        let test = (ProcessInfo.processInfo.environment["TEST_LOCATION"] ?? value("TestLocation"))?
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let pinned = test.flatMap { $0.count == 2 ? CLLocation(latitude: $0[0], longitude: $0[1]) : nil }
        return Aid.Config(
            wearer: wearer,
            background: value("WearerBackground") ?? "",
            situation: value("Situation") ?? "",
            answers: answers,
            // Same provider as the answers: same model too (the provider's default was gpt-oss,
            // whose 5/min cap rate-limited the coach in the first replay on qwen).
            coach: coachKey.map { Aid.Model(provider: coachProvider, key: $0, model: value("CoachModel")
                ?? (coachProvider == answerProvider ? answers?.model : nil) ?? coachProvider.model) },
            suggest: suggest,
            backup: backup,
            toolbox: value("Tools")?.lowercased() == "off" ? nil
                : DeviceTools(pinned: pinned, researcher: researcher, condenser: condenser),
            perMinute: value("AnswerPerMinute").flatMap { Int($0) },
            researcher: researcher)
    }
}
