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
    enum Kind: Equatable { case line, answer, define, insight, followup, research, lookup, learned, roles, status }
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

    /// "How much did they raise?", "when did that pass", "who runs the company": the question leans on
    /// something said earlier, so on its own it can't be answered or searched. Phrases where the
    /// word points at nothing ("is there", "what time is it") don't count.
    static func needsContext(_ question: String) -> Bool {
        var q = " " + normalized(question) + " "
        for idiom in [" is there ", " are there ", " was there ", " were there ", " what time is it ", " what day is it ",
                      " how far is it from ", " is it true ", " over there ", " out there "] {
            q = q.replacingOccurrences(of: idiom, with: " ")
        }
        let pointers = [" it ", " its ", " they ", " them ", " their ", " that ", " this ", " those ", " these ",
                        " he ", " him ", " his ", " she ", " her ", " there ", " the company ", " the startup ",
                        " the guy ", " the bill ", " the thing ", " the one ", " the same ", " the other ", " the place ",
                        " the book ", " the movie ", " the show ", " the paper ", " the law ", " the deal "]
        return pointers.contains { q.contains($0) }
    }

    /// "Who won the most recent Turing Award", "the latest on the GENIUS Act", "the current CEO": a
    /// question whose answer changes, so memory can't be trusted with it.
    static func wantsNow(_ question: String) -> Bool {
        let q = " " + normalized(question) + " "
        return [" latest ", " most recent ", " recently ", " newest ", " current ", " currently ", " right now ",
                " these days ", " nowadays ", " today ", " yesterday ", " this week ", " this month ", " this year ",
                " last year ", " last night ", " this season ", " so far "].contains { q.contains($0) }
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

    /// "What's your name?" (or "who are you"), from anyone: the next short line may be the answer.
    static func asksName(_ text: String) -> Bool {
        let t = " " + normalized(text) + " "
        return [" whats your name", " what is your name", " your name ", " who are you", " whats ur name"].contains { t.contains($0) }
    }

    /// The answer to "what's your name?": "Avi Shah", "It's Priya.", "Toby" → the name. One to three
    /// capitalized words, after an optional "it's" / "I'm" / "my name is"; anything longer or
    /// lower-case is a sentence, not a name.
    static func answeredName(_ text: String) -> String? {
        if let name = introducedName(in: text) { return name }
        var words = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .split(separator: " ").map(String.init)
        if let first = words.first?.lowercased(), ["it's", "its", "uh", "um", "oh", "yeah", "hi", "hey"].contains(first) { words.removeFirst() }
        guard (1...3).contains(words.count),
              words.allSatisfy({ $0.first?.isUppercase == true && $0.allSatisfy(\.isLetter) }) else { return nil }
        return words.joined(separator: " ")
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
/// Ran past its time limit. Nothing on the lens may think forever: a request that takes longer
/// than this is given up and says so.
struct Deadline: LocalizedError {
    var errorDescription: String? { "took too long" }
}

/// `work`, or `Deadline` after `seconds`, whichever comes first; the loser is cancelled.
func withDeadline<T>(_ seconds: Double, _ work: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw Deadline()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

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
        /// Jarvis: asked by name, so it may take a few seconds to think. Unset: `answers`.
        var jarvis: Model?
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
        /// Lines to say next (a lull, "Lens, what should I ask?", an opener for a face). Off: in
        /// the 2026-10-24 test with Joaquin they were bad enough to drop entirely; the coach still
        /// defines and still catches missed questions.
        var suggestions = true
        /// Insight cards: a fact or bit of context about what was just said.
        var insights = true
        /// Definitions and insights for the wearer's own lines too. Off: the wearer knows the words
        /// they say, and a judge replay defined "Meta Ray-Ban Display glasses" while the wearer was
        /// demoing them. The coach still reads their lines for the second look at questions.
        var defineMine = false
        /// The wearer's own questions get answers too, not only the other person's. In testing the
        /// wearer asks as much as anyone, and an ignored question reads as "it didn't hear me".
        var answerMine = false
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
    /// THEM introduced themselves ("I'm Priya"): the host can name a face it didn't know.
    @ObservationIgnored var onName: ((String) -> Void)?
    /// Whether the wearer is the one talking right now, if the host can tell (nil: it can't).
    @ObservationIgnored var liveWearer: (() -> Bool?)?
    /// The wearer's own record (CRM.digest: people met, what was said, promises, the roster), for
    /// what they ask Jarvis. Read per request, so it's always current.
    @ObservationIgnored var personal: (() -> String)?
    /// The person the wearer is talking to right now (face ID or the last one they looked at): their
    /// record line, so Jarvis knows who "they" are without a search. Empty when nobody is in front.
    @ObservationIgnored var currentPerson: (() -> String)?
    /// A Jarvis answer, to say out loud (Voice). Only answers to "Jarvis, …": the rest of the aid
    /// is silent on the lens.
    @ObservationIgnored var onJarvis: ((String) -> Void)?
    /// Tools only Jarvis gets: writing to the wearer's record (CRM.jarvisTools).
    @ObservationIgnored var jarvisTools: [ExtraTool] = []
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
            if newest.split(separator: " ").count >= 1, Date().timeIntervalSince(lastCoach) > 1.5,
               !isCommand(newest) { coachSoon() }
        }
        // "Jarvis" starting the sentence still being said shows the listening row now. The request
        // itself still waits for the sentence to close (`command`), so nothing fires early.
        // Only the wearer's own "Jarvis": someone else in the room saying it must not wipe an answer.
        if !wakeShownThisTurn, Tools.byName(open) {
            wakeShownThisTurn = true
            if wokenAt == nil { showWake() }
        }
        // A story has few full stops, so a sentence may stay open for minutes. Coach every ten words
        // of it as it's said, rather than holding everything for a pause.
        let openWords = open.split(separator: " ").count
        if openWords >= coachedOpenWords + 4, Date().timeIntervalSince(lastCoach) > 1.0, !isCommand(open) {
            coachedOpenWords = openWords
            coachSoon()
        }
        if !open.isEmpty { answerHeard(open, endpointed: false, mine: mine) }
        closeBuriedQuestion(open, mine: mine)
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
        endJarvisTurn()
        partial = ""
        saying = ""   // it's a line now
        closedInTurn = 0
        coachedOpenWords = 0
        wakeShownThisTurn = false
        openQuestion = nil
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
            // "I'm Priya", or a bare "Priya" answering "what's your name?" a moment ago (speaker
            // labels can't be trusted to tell who asked, so the answer is the line after).
            let answered = lines.last.map { Talk.asksName($0.text) && Date().timeIntervalSince($0.at) < 20 } == true
            if let name = Talk.introducedName(in: text) ?? (answered ? Talk.answeredName(text) : nil) {
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
                    onName?(name)
                }
            }
        }
        nextLine += 1
        lines.append(Line(id: nextLine, speaker: speaker, text: text, at: Date(), command: isCommand(text)))
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

        // Every real line, the wearer's too: a term they used ("financial derivatives") is worth a
        // card, and this is also the second look at a question the fast lane let go.
        if !Talk.isBackchannel(text), !isCommand(text) { coachSoon() }
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

    /// Someone nobody knows just became a contact: they're who the conversation is with now, and
    /// whoever face ID named before steps back, so the name they give is taken as theirs.
    func metStranger() {
        guard them.recognised else { return }
        others = Array(([them] + others.filter { $0.name != them.name }).prefix(4))
        them = Them()
        compositor.setHeader(nil)
        publish()
    }

    /// Everyone else face ID named in this conversation, most recent first.
    private(set) var others: [Them] = []

    /// Start over for a new conversation.
    func reset(trigger: String = "unknown") {
        SpeedLog.record(["event": "reset", "trigger": trigger, "cards": "\(compositor.view.cards.map(\.title))"])
        answerTask?.cancel(); coachTask?.cancel(); lookupTask?.cancel(); tickTask?.cancel(); silenceTask?.cancel(); jarvisTask?.cancel()
        lines = []; turns = []; events = []; them = Them(); others = []; ideas = []; roles = Roles(); partial = ""; status = ""
        // The cards are not cleared here: each one runs out on its own clock, so a conversation ending
        // doesn't take a Jarvis answer or a card with it.
        defined = []; noted = []; lastInsight = .distantPast; asked = []; answeredAt = .distantPast; firedText = ""; generation += 1
        coachPending = false; coachBlockedUntil = nil; closedInTurn = 0; openQuestion = nil
        wanted = nil; suggested = []; suggestedAt = .distantPast; turnStarted = nil; lastCommand = nil; saying = ""; jarvisTurn = nil
        publish()
    }

    /// A question said mid-flow with no pause after it ("…how many moons does Jupiter have and
    /// anyway I was saying…") never gets a full stop, so it would wait for the whole turn to end.
    /// Once the question is complete and the next words start something else, that is its endpoint.
    @ObservationIgnored private var openQuestion: String?
    private static let moveOn: Set<String> = [
        "and", "so", "but", "anyway", "i", "im", "like", "because", "cause", "then", "um", "uh",
        "yeah", "okay", "ok", "we", "it", "its", "or", "also", "wait", "actually",
    ]

    private func closeBuriedQuestion(_ open: String, mine: Bool) {
        let now = QuestionGate.candidate(in: open)
        if let asked = openQuestion {
            let extra = now.flatMap { $0.text.hasPrefix(asked) ? String($0.text.dropFirst(asked.count)).trimmed : nil }
            let first = extra?.split(separator: " ").first.map(String.init)
            // Gone (the clause changed) or carried on into a new thought: the question was whole.
            if extra == nil || first.map(Self.moveOn.contains) == true {
                openQuestion = nil
                answerHeard(asked + "?", endpointed: true, mine: mine)
                return
            }
        }
        if let now, now.confidence == .strong { openQuestion = now.text }
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
    /// Words of the turn still open (no full stop yet) when the coach last looked at it.
    @ObservationIgnored private var coachedOpenWords = 0
    @ObservationIgnored private var nextCard = 0

    /// `mine`: the wearer is the one asking. Then the other person is about to answer, and an
    /// answer on the lens only competes with them (the judge, on "how long does that take":
    /// "encouraging Toby to look away from the person actually answering").
    private func answerHeard(_ text: String, endpointed: Bool, mine: Bool) {
        guard config.answers != nil else { return }
        // Where, weather, my calendar: worth answering whoever asked, and only a tool can.
        let toolish = config.toolbox != nil && Tools.wants(text)
        if mine, roles.known, !toolish, !config.answerMine {
            if endpointed { commit(nil) }
            return
        }
        guard let candidate = QuestionGate.candidate(in: text) else {
            if endpointed { commit(nil) }
            return
        }
        // "How much did they raise?": who "they" are was said earlier. Wait for the whole question,
        // rewrite it to stand alone from the last few minutes, then answer that.
        if !resolvedPass, Talk.needsContext(candidate.text), Answerer.local(candidate.text) == nil {
            if endpointed { resolveThenAnswer(candidate.text, mine: mine) }
            return
        }
        if config.explicitOnly, endpointed, !text.trimmed.hasSuffix("?"), candidate.confidence != .strong {
            abandon()
            return
        }
        // "The most recent", "latest", "current": memory is out of date by definition. Straight to
        // the web once the question closes, with no guess from memory first: "who won the most recent
        // Turing Award?" got 2024's winners from memory; the web had 2025's.
        if config.researcher != nil, Talk.wantsNow(candidate.text), Answerer.local(candidate.text) == nil {
            guard endpointed else {
                abandon()
                return
            }
            // A guess still in flight for this question is dropped; the lookup takes its card.
            let card = turns.first.flatMap { $0.live ? $0.card : nil }
            if !firedText.isEmpty {
                answerTask?.cancel()
                generation += 1
                if turns.first?.live == true { turns[0].state = .skipped }
                firedText = ""
            }
            lookUp(candidate.text, card: card)
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

    /// Set while a rewritten question goes back through `answerHeard`, so it isn't rewritten again.
    @ObservationIgnored private var resolvedPass = false
    @ObservationIgnored private var resolving: String?

    private func resolveThenAnswer(_ question: String, mine: Bool) {
        guard resolving != question, let using = model(config.answers, blockedUntil: answersBlockedUntil) ?? config.backup else { return }
        resolving = question
        // Far more of the conversation than a plain answer gets: the referent can be minutes back.
        let context = self.context(last: 30)
        let started = Date()
        Task { [weak self] in
            let standalone = try? await Answerer.standalone(question, context: context, provider: using.provider,
                                                            key: using.key, model: using.model)
            guard let self else { return }
            self.resolving = nil
            switch standalone {
            case nil:
                // The rewrite failed: the question as said, with the conversation as context, still
                // beats nothing.
                self.resolvedPass = true
                self.answerHeard(question + "?", endpointed: true, mine: mine)
                self.resolvedPass = false
            case let text? where text == "SKIP":
                self.log(.status, "Skipped \"\(question)\": personal, or the conversation doesn't say what it means")
            case let text?:
                self.log(.status, "Resolved \"\(question)\" → \(text) · \(self.ms(since: started)) ms")
                self.resolvedPass = true
                self.answerHeard(text, endpointed: true, mine: mine)
                self.resolvedPass = false
            }
        }
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
            lookUp(candidate.text, card: turn.card)
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

    /// When the fast lane last took a question, by any path; the coach's second look stands down.
    @ObservationIgnored private var fastLaneAt = Date.distantPast

    private func fire(_ question: String, committed: Bool = false) {
        guard let answers = model(config.answers, blockedUntil: answersBlockedUntil) else { return }
        fastLaneAt = Date()
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
                    } catch AnswerError.http(let code) where (code == 429 || code == 402) && !any {
                        // Rate-limited (or out of quota: 402) before a word arrived: this answer and the
                        // next minute's (ten, out of quota) go to the backup.
                        guard let backup, backup != using else { throw AnswerError.http(code) }
                        self?.answersBlockedUntil = Date().addingTimeInterval(code == 402 ? 600 : 60)
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
                if let turn = self.turns.first, turn.committedAt != nil { self.lookUp(turn.question, card: turn.card) }
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
            // Nothing goes up until the answer's first words: a "…" put up the moment a question
            // started flashed and vanished on every personal question the model then skipped (1-2
            // per judge replay). The fire is speculative, so the words usually land as the question
            // ends anyway. They replace each other as the answer streams.
            // The same question again within 15 s (asked twice, or re-fired as the transcript grew):
            // what's up stays up. A different question is the only reason to change it.
            if let last = settled, last.card != turn.card, now.timeIntervalSince(last.at) < 15,
               compositor.view.cards.contains(where: { $0.id == last.card }),   // only while it's still up
               Talk.echoes(turn.question, last.question) || Talk.echoes(last.question, turn.question) {
                return
            }
            // The question is fixed the first time it goes up, and so is a finished answer.
            let answer = finalAnswer[turn.card] ?? turn.answer
            guard !answer.isEmpty else { return }
            let question = shownQuestion[turn.card] ?? turn.question
            shownQuestion[turn.card] = question
            answeredAt = now
            answeredText = question + " " + answer
            if turn.state == .done, finalAnswer[turn.card] == nil {
                finalAnswer[turn.card] = answer
                settled = (turn.card, question, now)
            }
            compositor.show(Card(kind: .answer, title: answer,
                                 detail: Self.echo(question),
                                 live: finalAnswer[turn.card] == nil, id: turn.card), at: now)
        case .skipped where turn.lookup:
            // Needs the web: the question stays up, and the lookup's answer replaces this.
            compositor.show(Card(kind: .answer, title: "Looking it up\u{2026}", detail: Self.echo(shownQuestion[turn.card] ?? turn.question),
                                 live: true, id: turn.card), at: now)
        case .skipped, .failed:
            compositor.remove(id: turn.card, kind: .answer, at: now)
        }
        publish()
    }

    /// The lens is small: echo just enough of the question to make the answer legible.
    /// A tool's title and detail as one answer: each "·" part once, and none the question already
    /// says. "London · 5368 mi" + "~13 hr flight · London" for "how far is London" → "5368 mi · ~13 hr flight".
    private static func tidy(_ title: String, _ detail: String, asked: String) -> String {
        let question = asked.lowercased()
        var seen = Set<String>()
        let parts = (title + " \u{00B7} " + detail).components(separatedBy: "\u{00B7}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        // A part is old news when most of its words are already in the question ("Great Wall,
        // Mutianyu" for "how far is the Great Wall"). Two parts at most: the fact and its context.
        let asked = Set(question.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let fresh = parts.filter { part in
            let words = part.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            return words.isEmpty || words.filter(asked.contains).count * 2 < words.count
        }
        return (fresh.isEmpty ? parts : fresh).prefix(2).joined(separator: " \u{00B7} ")
    }

    /// A how or why question wants a few sentences; "how far / many / much / long / old" wants a number.
    static func explains(_ question: String) -> Bool {
        let q = question.lowercased().trimmingCharacters(in: .whitespaces)
        let numeric = ["how far", "how many", "how much", "how long", "how old", "how big", "how tall", "how fast"]
        if numeric.contains(where: q.contains) { return false }
        return q.hasPrefix("why") || q.hasPrefix("how") || q.contains(" why ") || q.contains(" how does ")
            || q.contains("explain")
    }

    /// The question exactly as asked: small and grey, it wraps rather than being cut.
    private static func echo(_ question: String) -> String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func words(_ s: String) -> Int { s.split(separator: " ").count }

    // MARK: - Tools: things only the device knows or can do

    @ObservationIgnored private var lastCommand: (text: String, at: Date)?
    /// "Jarvis." on its own: when, and the row on the lens saying it's listening.
    @ObservationIgnored private var wokenAt: (at: Date, card: Int)?
    /// The listening row was already shown for the turn in progress, so partials don't re-show it.
    @ObservationIgnored private var wakeShownThisTurn = false
    /// How long a bare "Jarvis." waits for the request.
    static let wakeWindow: TimeInterval = 8
    /// The last sentence taken as a request after a bare "Jarvis.", so it isn't conversation.
    @ObservationIgnored private var consumed: (text: String, at: Date)?

    /// Said to the glasses, not to anyone in the room: kept out of the coach, the transcript's
    /// questions and the CRM.
    func isCommand(_ text: String) -> Bool {
        if Tools.command(in: text) != nil || Tools.wakeOnly(text) { return true }
        guard let consumed, Date().timeIntervalSince(consumed.at) < 20 else { return false }
        let said = Talk.normalized(text), request = Talk.normalized(consumed.text)
        return !request.isEmpty && (said.contains(request) || request.contains(said))
    }

    /// "Jarvis, …" or "Lens, …" from the wearer: "what should I ask?" gets a suggestion, anything
    /// else goes to the tool model with the whole context, and Jarvis also gets the wearer's own
    /// record. "Jarvis" counts from anyone (nobody says it to the person in front of them, and a
    /// mislabelled wearer must not be ignored); "Lens" only from the wearer once roles are known.
    /// True when `sentence` was a command, handled or deliberately dropped.
    private func command(_ sentence: String, mine: Bool) -> Bool {
        guard config.toolbox != nil else { return false }
        if Tools.wakeOnly(sentence) {
            if wokenAt == nil || Date().timeIntervalSince(wokenAt!.at) > 2 { showWake() }
            return true
        }
        // More of a turn that began "Jarvis, …": part of the request ("Marcus works at DeepMind.
        // What did they announce?").
        if var turn = jarvisTurn, Tools.command(in: sentence) == nil, sentence.contains(where: \.isLetter) {
            turn.text += " " + sentence
            jarvisTurn = turn
            consumed = (sentence, Date())
            jarvisHeard(turn.text)
            return true
        }
        let named = Tools.byName(sentence)
        let request: String
        if let said = Tools.command(in: sentence) {
            request = said
        } else if let woken = wokenAt, Date().timeIntervalSince(woken.at) < Self.wakeWindow,
                  sentence.contains(where: \.isLetter), !Talk.isBackchannel(sentence) {
            // The sentence after a bare "Jarvis." is the request.
            request = sentence
            consumed = (sentence, Date())
        } else {
            return false
        }
        let jarvis = named || wokenAt != nil
        wokenAt = nil
        guard mine || jarvis || !roles.known else { return true }   // the other person saying "lens" isn't asking us
        // The same sentence arrives twice, as a partial and as the finished line; a few seconds
        // later it's a new request.
        if let last = lastCommand, Talk.normalized(request) == Talk.normalized(last.text),
           Date().timeIntervalSince(last.at) < 8 { return true }
        lastCommand = (request, Date())
        // Jarvis takes "what should I say?" too: it has the whole conversation and the record.
        if !jarvis, Talk.asksForSuggestion(request) {
            suggestNow()
        } else if jarvis {
            jarvisTurn = (request, nil)
            jarvisHeard(request)
        } else {
            toolRound(request, command: true)
        }
        return true
    }

    /// The "Listening…" row, up for `wakeWindow` seconds unless a request replaces it.
    private func showWake() {
        nextCard += 1
        wokenAt = (Date(), nextCard)
        jarvisTask?.cancel()
        compositor.startJarvis("Listening\u{2026}", at: Date())
        log(.status, "Jarvis listening")
        publish()
        let card = nextCard
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.wakeWindow))
            guard let self, self.wokenAt?.card == card else { return }
            self.wokenAt = nil
            self.compositor.clearJarvis()
            self.publish()
        }
    }

    /// The last Jarvis exchanges, most recent last, fed back to Jarvis as context.
    @ObservationIgnored private var jarvisHistory: [(question: String, answer: String)] = []

    /// The request said to Jarvis so far this turn, and what of it is already being worked on.
    @ObservationIgnored private var jarvisTurn: (text: String, fired: String?)?

    /// A question is complete at its "?": Jarvis starts on it (again, if more was added). A
    /// statement waits for the rest of the turn (`endJarvisTurn`), with the panel up meanwhile.
    private func jarvisHeard(_ text: String) {
        if text.trimmingCharacters(in: .whitespaces).hasSuffix("?") {
            fireJarvis()
        } else if jarvisTurn?.fired == nil {
            jarvisTask?.cancel()
            compositor.startJarvis(Self.echo(text), at: Date())
            publish()
        }
    }

    private func fireJarvis() {
        guard let turn = jarvisTurn, turn.fired != turn.text else { return }
        jarvisTurn?.fired = turn.text
        jarvisRound(turn.text)
    }

    /// The speaker stopped: whatever they said to Jarvis is the request.
    private func endJarvisTurn() {
        fireJarvis()
        jarvisTurn = nil
    }

    /// One request that may need a tool: the model answers, skips, or names a tool; the device
    /// runs it; the result goes up as an answer card as it is, no second model call. A command
    /// shows what it's doing if the tool takes a moment; an overheard question just shows the result.
    private func toolRound(_ request: String, command: Bool) {
        guard let toolbox = config.toolbox, let primary = model(config.answers, blockedUntil: answersBlockedUntil) else { return }
        nextCard += 1
        let card = nextCard, echo = Self.echo(request), started = Date()
        fastLaneAt = started
        // In flight counts as answered: the coach's second look at the same line ("…near Cal Hacks
        // 13.0?") put "Great China" up twice.
        answeredAt = started
        answeredText = request
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
                    self.log(.lookup, request, detail: "tool model skipped · \(used.model)")
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
                    let result = try await withDeadline(15) { try await toolbox.run(name, arguments: arguments) }
                    ack?.cancel()
                    guard !Task.isCancelled else { return }
                    self.compositor.endWork(id: card)
                    // Research that found nothing ("Not yet announced") isn't worth a glance.
                    guard !result.title.isEmpty else {
                        if command { self.put(Card(kind: .answer, title: "Couldn't find that", detail: echo, id: card)) }
                        self.log(.lookup, request, detail: "no answer found")
                        return
                    }
                    // The question line is only ever the question: the tool's own detail joins the answer.
                    // Research gives a fact plus a paragraph: the paragraph only for a how or why.
                    let answer = name == "research" && !Self.explains(request) ? result.title
                        : Self.tidy(result.title, result.detail, asked: request)
                    self.put(Card(kind: .answer, title: answer, detail: echo, id: card, icon: result.icon))
                    self.log(.answer, result.title, detail: "\(request) · \(name) · \(self.ms(since: started)) ms · \(used.model)")
                }
                self.timings["tool", default: []].append(self.ms(since: started))
            } catch {
                guard !Task.isCancelled else { return }
                if command { self?.put(Card(kind: .answer, title: "Couldn't do that", detail: echo, id: card, icon: "exclamationCircle")) }
                self?.lastCommand = nil
                self?.log(.status, "Tool failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Jarvis: asked by name, thinks, shows its work

    @ObservationIgnored private var jarvisTask: Task<Void, Never>?
    /// The longest Jarvis may think, tools and all, before it gives up and says so.
    nonisolated static let jarvisLimit: TimeInterval = 25

    /// The wearer asked Jarvis: its panel goes up at once, every step shows as it happens, and
    /// the answer lands in the panel (and in their ear, `onJarvis`). A new request replaces one
    /// still thinking. Runs on `config.jarvis`, a bigger model than the passing answers.
    private func jarvisRound(_ request: String) {
        guard let base = config.toolbox, let model = config.jarvis ?? config.answers ?? config.backup else { return }
        var extras = jarvisTools
        // Research hands Jarvis what was found, not a six-word card: the model reads it itself.
        if let researcher = config.researcher {
            extras.append(ExtraTool(name: "research", definition: DeviceTools.research,
                                    working: researcher.name.contains("Fetch") ? "Asking Fetch.ai" : "Searching the web") { json in
                let task = Tools.arguments(json)["task"] as? String ?? ""
                guard !task.isEmpty else { return ToolResult(title: "No task given.", detail: "", icon: "") }
                let finding = try await researcher.research(task, context: "")
                return ToolResult(title: String(finding.prefix(4000)), detail: "", icon: "")
            })
        }
        let toolbox: any Toolbox = extras.isEmpty ? base : ExtraTools(base: base, extras: extras)
        let wearer = config.wearer
        let started = Date()
        jarvisTask?.cancel()
        compositor.startJarvis(Self.echo(request), at: started)
        // Jarvis knows the wearer's life: who they are, who they've met, what they owe.
        // Where they are and what they're doing, the person in front of them, then their whole record.
        let here = config.situation.isEmpty ? "" : "Where and what: \(config.situation)"
        let front = currentPerson?() ?? ""
        let record = [here,
                      config.background.isEmpty ? "" : "About \(config.wearer): \(config.background)",
                      front.isEmpty ? "" : "Talking with them now:\n\(front)",
                      personal?() ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        if personal != nil { compositor.jarvisStep("Reading your notes", at: started) }
        publish()
        // The last few Jarvis exchanges, so "and in Spanish?" or "what about the second one" make sense.
        let context = jarvisHistory.map { "Earlier, asked Jarvis: \($0.question) Answer: \($0.answer)" }.joined(separator: "\n")
            + "\n" + self.context(last: 30)
        let fallback = config.jarvis != nil ? config.answers : nil
        jarvisTask = Task { [weak self] in
            let step: @Sendable (String) async -> Void = { label in
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.compositor.jarvisStep(label, at: Date())
                    self.publish()
                }
            }
            var used = model
            var answer: String
            let started = Date()
            do {
                do {
                    answer = try await withDeadline(Self.jarvisLimit) {
                        try await Tools.think(request, context: context, personal: record, wearer: wearer, toolbox: toolbox, model: model, step: step)
                    }
                } catch where fallback != nil && !Task.isCancelled && !(error is Deadline) {
                    // The big model is down or rate-limited: the fast one still answers, in what's left.
                    await MainActor.run { self?.log(.status, "Jarvis on the fast model: \(error.localizedDescription)") }
                    used = fallback!
                    let left = max(4, Self.jarvisLimit - Date().timeIntervalSince(started))
                    answer = try await withDeadline(left) {
                        try await Tools.think(request, context: context, personal: record, wearer: wearer, toolbox: toolbox, model: used, step: step)
                    }
                }
            } catch is Deadline {
                guard !Task.isCancelled else { return }
                self?.log(.status, "Jarvis gave up after \(Int(Self.jarvisLimit)) s: \(request)")
                answer = "That was taking too long. Try asking for just the name or the key fact."
            } catch {
                guard !Task.isCancelled else { return }
                self?.log(.status, "Jarvis failed: \(error.localizedDescription)")
                self?.lastCommand = nil   // a retry of the same question is a new request, not a repeat
                answer = "I couldn't do that."
            }
            guard !Task.isCancelled, let self else { return }
            self.compositor.jarvisAnswer(answer, at: Date())
            if answer != "I couldn't do that." {
                self.jarvisHistory = Array((self.jarvisHistory + [(request, answer)]).suffix(3))
            }
            self.answeredAt = Date()
            self.answeredText = answer
            self.publish()
            self.log(.answer, answer, detail: "\(request) · jarvis · \(self.ms(since: started)) ms · \(used.model)")
            self.timings["jarvis", default: []].append(self.ms(since: started))
            self.onJarvis?(answer)
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
    /// Insight topics shown this conversation.
    @ObservationIgnored private var noted: [String] = []
    /// When each defined term and noted topic was last used, keyed "d:term" / "n:topic". Both fall out
    /// of memory after `memoryLife`, so an old topic can come back rather than block the lens all talk.
    @ObservationIgnored private var memoryAt: [String: Date] = [:]
    static let memoryLife: TimeInterval = 180

    private func pruneMemory(now: Date = Date()) {
        let stale = memoryAt.filter { now.timeIntervalSince($0.value) > Self.memoryLife }.map(\.key)
        guard !stale.isEmpty else { return }
        for key in stale { memoryAt[key] = nil }
        defined.removeAll { stale.contains("d:" + $0.lowercased()) }
        noted.removeAll { stale.contains("n:" + $0.lowercased()) }
    }

    /// One call at a time; anything heard meanwhile folds into one more call right after.
    private func coachSoon() {
        guard config.coach != nil else { return }
        if coachTask != nil {
            coachPending = true
            return
        }
        // Suggestions off (`aidSuggest`, the default): every call is for definitions and missed questions.
        let moment = config.suggestions ? wanted : nil
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
        // What this call is about: the turn still being spoken, else the last line, and whose it is.
        // Checked when the reply lands instead, the conversation has often moved on to the next one.
        let lastLine = lines.last { !$0.command }
        let lookedAt = partial.isEmpty ? (lastLine?.text ?? "") : partial
        let mine = partial.isEmpty ? roles.isWearer(lastLine?.speaker) : predictedWearer()
        let finished = partial.isEmpty
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
                self?.apply(advice, for: moment, lookedAt: lookedAt, mine: mine, finished: finished)
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
        pruneMemory()
        // Definitions and insights read the last few lines; a suggestion for this moment reads more.
        var transcript = transcriptLines(last: moment == nil ? 8 : 30)
        if !partial.isEmpty { transcript.append("\(predictedTag()) (still talking): \(partial)") }
        // The coach writes a suggestion only for a moment, and for that moment.
        let why: String? = switch moment {
        case .lull: "a silence; revive the best thread"
        case .asked: "the wearer asks what to say next"
        case .recognised: "face ID just recognised THEM; pick up where you left off last time"
        case nil: nil
        }
        return Coach.Input(wearer: config.wearer, background: config.background, situation: config.situation, known: known,
                           defined: defined, noted: noted, suggested: suggested, moment: why, transcript: transcript)
    }

    /// `moment`: the moment this call was asked to write a suggestion for, if any.
    private func apply(_ advice: Coach.Advice, for moment: Moment?, lookedAt utterance: String, mine: Bool, finished: Bool) {
        let now = Date()
        pruneMemory(now: now)
        let recent = Talk.normalized((lines.suffix(2).map(\.text) + [partial]).joined(separator: " "))
        // Only a term just said, of real substance, that the coach is sure of: "LO — likely
        // misheard LLM" (it was Elo) is worse than nothing.
        let unsure = ["misheard", "likely", "probably", "possibly", "unclear", "perhaps"]
        // Not a term an answer card just covered: "what's Cohen's kappa?" got an answer and then the
        // same thing again as a definition.
        let answered = now.timeIntervalSince(answeredAt) < 15 ? Talk.normalized(answeredText) : ""
        // A question in the line the coach looked at gets an answer, not a definition or an insight
        // about its subject: "Turing Award" was defined, and a wrong winner put up, while the judge
        // was still asking who won it. And the wearer's own words only with `defineMine`.
        let asking = utterance.contains("?") || QuestionGate.candidate(in: utterance) != nil
        let quiet = asking || (mine && !config.defineMine)
        // Questions asked in the last 20 s: an insight on their subject repeats the answer.
        let questions = turns.prefix(4).filter { now.timeIntervalSince($0.firedAt) < 20 }.map { Talk.normalized($0.question) }
        // A term the wearer used is one they know: "GARCH" was defined right after "Some GARCH, some
        // realized vol" (the judge: 2/8, during the recruiting moment).
        let theirOwn = Talk.normalized(lines.suffix(10).filter { roles.isWearer($0.speaker) }.map(\.text).joined(separator: " ")
            + (predictedWearer() ? " " + partial : ""))
        // Where they are and who they are is known already: the event they're at ("CalHacks") is not news.
        let known = Talk.normalized(config.situation + " " + config.background).filter { $0 != " " }
        for term in advice.define where !Talk.mentioned(term.term, in: theirOwn) && !defined.contains(where: { Talk.mentioned($0, in: Talk.normalized(term.term + " " + (term.meaning ?? ""))) })
            && term.term.count >= 3 && Talk.mentioned(term.term, in: recent) && !Talk.mentioned(term.term, in: answered)
            && !known.contains(Talk.normalized(term.term).filter { $0 != " " }) && !quiet {
            defined.append(term.term)
            memoryAt["d:" + term.term.lowercased()] = Date()
            // No meaning, or one the coach isn't sure of: search for it instead of guessing.
            guard let meaning = term.meaning, !unsure.contains(where: meaning.lowercased().contains) else {
                lookUp("What is \(term.term)?")
                continue
            }
            nextCard += 1
            compositor.show(Card(kind: .definition, title: term.term, detail: meaning, id: nextCard), at: now)
            log(.define, term.term, detail: meaning)
        }
        // A fact about the topic, from the web (`ground`): more to know, never a line to say. Once
        // per topic, one every `insightGap`, not one a definition or an answer just covered, not on
        // a question. Only about what was just said: a garbled line ("you never sink holy") got an
        // insight on Calvisius from 40 s before.
        if config.insights, let insight = advice.insight, !quiet, !Talk.mentioned(insight.topic, in: theirOwn),
           !questions.contains(where: { Talk.mentioned(insight.topic, in: $0) }),
           Talk.mentioned(insight.topic, in: recent) || Talk.mentioned(insight.query, in: recent),
           now.timeIntervalSince(lastInsight) >= Self.insightGap,
           !noted.contains(where: { Talk.same($0, insight.topic) }),
           !defined.contains(where: { Talk.same($0, insight.topic) || Talk.mentioned($0, in: Talk.normalized(insight.topic)) }),
           !Talk.mentioned(insight.topic, in: answered) {
            ground(insight, line: utterance)
        }
        // The recognizer garbled a request the gate or the answer model let go: the coach's clean
        // version goes to the tool model (answer, device tool or Fetch), unless something already
        // answered this turn.
        // This is the second look at every line: the fast lane drops a question the recognizer
        // ended with "." instead of "?", one the gate didn't recognise, or one it thought was
        // the wearer's to leave alone. Only if someone asked something ("we just raised a seed
        // around" was rebuilt into a question and answered with a made-up number), and unless
        // that same question was answered or is in flight.
        let newest = (lines.last { !$0.command }?.text ?? "") + " " + partial
        // The fast lane already has a question from the last 10 s: it answers that one; the coach's
        // rewrite ("how far" → "how long") would only put up a second, different answer.
        // Any of its paths counts (a direct answer, a tool, a lookup), however the coach worded it:
        // "what is the distance between Berkeley and San Francisco" put "13.9 miles" up twice.
        let fastLaneBusy = now.timeIntervalSince(fastLaneAt) < 5
            || (turns.first.map { now.timeIntervalSince($0.firedAt) < 10 } ?? false)
        // Only a question that was finished, and only a rewrite of what was said: mid-sentence, at
        // "Okay, quick test. Who…", the coach finished the question itself ("Who is the founder of
        // OpenAI?") and "Sam Altman" went up for something nobody asked.
        let grounded = advice.ask.map { (finished || utterance.contains("?")) && Talk.mentioned($0, in: Talk.normalized(utterance)) } ?? false
        if let ask = advice.ask, grounded, Talk.asks(newest), lookupTask == nil, turns.first?.live != true, !fastLaneBusy,
           !alreadyAnswered(ask, at: now), !asked.contains(where: { Talk.same($0, ask) }) {
            asked.append(ask)
            answeredAt = now
            // A place question goes to the tools as asked: "near here" is where the device is, and
            // the rewrite ("near Cal Hacks 13.0 at UC Berkeley") sent Maps to a café 10 miles away.
            let request = Tools.wants(newest) ? (QuestionGate.candidate(in: newest.trimmed)?.text ?? ask) : ask
            log(.lookup, request, detail: "caught on the second look")
            toolRound(request, command: false)
        }
        // Shown only while its moment lasts: speech ends a lull (`wanted` is cleared), so a line that
        // arrives after they started talking again stays off the lens.
        if let moment, wanted != nil {
            // A lull is optional: a line the coach itself rates as one anyone could say isn't worth
            // breaking the silence for. Asked for, or a face just recognised, the best one goes up.
            let good = moment != .lull || (advice.score ?? 3) >= 2
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
            let fresh = advice.alternatives.filter { ($0.score ?? 3) >= 2 }.map(\.say)
                .filter { text in usable(text) && !ideas.contains { Talk.same($0.text, text) } }
            ideas = Array((fresh.map { (text: $0, at: now, line: lines.count) } + ideas).prefix(4))
        }
        if status.hasPrefix("Coach") { status = "" }
        publish()
    }

    // MARK: - Insights: one fact the web backs, about what was just said
    //
    // The coach names the topic and a search; Exa runs it and a fast model writes the one fact the
    // results support (`Coach.fact`). From memory alone a judge replay put up "the 2024 Turing Award
    // went to Andrej Karpathy and Yann LeCun", wrong on both counts, about the judge's own field. A
    // fact the web backs costs ~0.8 s more, and an insight is never urgent.

    @ObservationIgnored private var lastInsight = Date.distantPast
    /// At most one insight this often: the least urgent card mustn't crowd out the rest.
    private static let insightGap: TimeInterval = 0.5
    /// Later than this after the line, the conversation has moved on: dropped.
    private static let insightLate: TimeInterval = 8

    private func ground(_ insight: (topic: String, query: String), line: String) {
        guard let researcher = config.researcher,
              let writer = (config.perMinute != nil ? config.backup : nil) ?? config.answers ?? config.backup else { return }
        noted.append(insight.topic)
        memoryAt["n:" + insight.topic.lowercased()] = Date()
        lastInsight = Date()
        let started = Date()
        Task { [weak self] in
            do {
                let notes = try await researcher.research(insight.query, context: "")
                let fact = try await Coach.fact(about: insight.topic, line: line, notes: notes,
                                                provider: writer.provider, key: writer.key, model: writer.model)
                guard let self else { return }
                let ms = self.ms(since: started)
                guard let fact, Double(ms) < Self.insightLate * 1000 else {
                    self.log(.lookup, insight.query, detail: fact == nil ? "insight: nothing specific found" : "insight: too late (\(ms) ms)")
                    return
                }
                self.nextCard += 1
                self.compositor.show(Card(kind: .insight, title: insight.topic, detail: fact, id: self.nextCard), at: Date())
                self.timings["insight", default: []].append(ms)
                self.log(.insight, insight.topic, detail: fact)
                self.publish()
            } catch {
                self?.log(.lookup, insight.query, detail: "insight: \(error.localizedDescription)")
            }
        }
    }

    /// The first call of a session pays for DNS, TLS and a cold route; the first place question for
    /// a location fix and its street name (up to ~2 s). Done when listening starts, so the first
    /// question in front of someone is as quick as the tenth.
    func warm() {
        for lane in [config.answers, config.coach == config.answers ? nil : config.coach].compactMap({ $0 }) {
            Task.detached {
                var body: [String: Any] = ["model": lane.model, "messages": [["role": "user", "content": "hi"]]]
                body.merge(lane.provider.extras(model: lane.model)) { _, extra in extra }
                body["max_tokens"] = 1
                _ = try? await LLM.complete(lane.provider.endpoint, key: lane.key, body: body, timeout: 5)
            }
        }
        if config.researcher is Exa {
            Task.detached { _ = try? await URLSession.shared.data(from: URL(string: "https://api.exa.ai/")!) }
        }
        if let toolbox = config.toolbox { Task { _ = await toolbox.whereabouts() } }
    }

    /// Something on the lens in the last 20 s already answers `question`: a turn that asked the
    /// same thing, or an answer card about it.
    private func alreadyAnswered(_ question: String, at now: Date) -> Bool {
        let recent = turns.prefix(4).filter { turn in
            guard turn.state == .done || turn.live else { return false }
            return now.timeIntervalSince(turn.committedAt ?? turn.firedAt) < 20
        }
        if recent.contains(where: { Talk.same($0.question, question) }) { return true }
        return now.timeIntervalSince(answeredAt) < 20 && Talk.same(answeredText, question)
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

    /// Seconds of quiet after a line that count as a lull. One: very eager.
    private static let lull: TimeInterval = 1

    /// The wearer asks what to say: a pinch on the glasses, "Lens, what should I ask?", `s` on the Mac.
    func suggestNow() {
        offer(.asked)
    }

    private func offer(_ moment: Moment) {
        guard config.coach != nil, config.suggestions else { return }
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
        guard config.suggestions else { return }   // definitions and answers only
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
            guard !last.isEmpty, !isCommand(last), !(theirs && last.contains("?")) else { return }
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
    /// `card`: the question's own card, so the answer lands in place of "Looking it up…".
    private func lookUp(_ question: String, card existing: Int? = nil) {
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
        fastLaneAt = answeredAt
        let card = existing ?? { nextCard += 1; return nextCard }(), started = Date()
        compositor.startWork(id: card, label: config.toolbox?.working("research", arguments: "{}") ?? "Looking it up", at: started)
        publish()
        // Where they are resolves "this thing" and "here"; who they are never goes out.
        let context = (config.situation.isEmpty ? "" : "Where: \(config.situation)\n") + transcript(last: 4)
            + (saying.isEmpty ? "" : "\n" + saying)
        let condenser = (config.perMinute != nil ? config.backup : nil) ?? config.answers ?? config.backup
        lookupTask = Task { [weak self] in
            do {
                let finding = try await withDeadline(15) { try await researcher.research(question, context: context) }
                var result = ToolResult(title: String(finding.prefix(60)), detail: "", icon: "starCircleTriangleAi")
                if let condenser {
                    result = try await Tools.card(from: finding, about: question, provider: condenser.provider,
                                                  key: condenser.key, model: condenser.model)
                }
                guard let self else { return }
                self.compositor.endWork(id: card)
                guard !result.title.isEmpty else {
                    self.log(.lookup, question, detail: "no answer found")
                    self.dropPlaceholder(card)
                    self.publish()
                    self.lookupTask = nil
                    return
                }
                // This question's own direct answer stays: it would change under the wearer's eyes.
                // Another question's answer is no reason to drop this one.
                if self.finalAnswer[card] != nil {
                    self.log(.lookup, question, detail: "kept the direct answer over \(result.title)")
                    self.publish()
                    self.lookupTask = nil
                    return
                }
                // Same shape as a direct answer: the question small on top, the answer under it.
                let answer = Self.explains(question) && !result.detail.isEmpty ? result.title + ". " + result.detail : result.title
                self.put(Card(kind: .answer, title: answer, detail: Self.echo(question), id: card, icon: result.icon))
                let ms = self.ms(since: started)
                self.timings["research", default: []].append(ms)
                self.log(.research, result.title, detail: "\(result.detail) · \(question) · \(ms) ms")
            } catch {
                self?.log(.status, "Lookup failed: \(error.localizedDescription)")
                self?.dropPlaceholder(card)
            }
            self?.compositor.endWork(id: card)
            self?.publish()
            self?.lookupTask = nil
        }
    }

    /// A lookup that ends with nothing to show takes its "Looking it up…" card down with it.
    private func dropPlaceholder(_ card: Int) {
        if finalAnswer[card] == nil { compositor.remove(id: card, kind: .answer, at: Date()) }
    }

    // MARK: - Lens

    @ObservationIgnored private var compositor = Compositor()
    /// Per card: the question as first shown, and the answer once finished. Neither changes after.
    @ObservationIgnored private var shownQuestion: [Int: String] = [:]
    @ObservationIgnored private var finalAnswer: [Int: String] = [:]
    /// The last finished answer's card, question and time, so a repeat of it doesn't replace it.
    @ObservationIgnored private var settled: (card: Int, question: String, at: Date)?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    private func publish() {
        for entry in compositor.drainJournal() { SpeedLog.record(entry.merging(["event": "card"]) { $1 }) }
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
        // JARVIS_* in the environment wins, for comparing models on the Mac without a rebuild.
        let env = ProcessInfo.processInfo.environment
        let jarvisProvider = Provider(rawValue: (env["JARVIS_PROVIDER"] ?? value("JarvisProvider"))?.lowercased() ?? "")
        let jarvis = jarvisProvider.flatMap { provider in
            (env["JARVIS_API_KEY"] ?? value("JarvisAPIKey")).map {
                Aid.Model(provider: provider, key: $0, model: env["JARVIS_MODEL"] ?? value("JarvisModel") ?? provider.model)
            }
        }
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
            jarvis: jarvis,
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
