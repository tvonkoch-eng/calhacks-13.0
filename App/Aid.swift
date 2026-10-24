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

/// Who the other person is: what face ID knows about them (`Aid.met`), plus what they say.
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
    /// the aid can't know. An interjection asks or says something to the other person instead.
    static func speaksForWearer(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").trimmingCharacters(in: .whitespaces)
        return ["no,", "no ", "nope", "yes", "yeah", "yep", "i ", "i'm", "i've", "i'd", "i'll", "my ", "me "]
            .contains { t.hasPrefix($0) }
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

/// The conversation aid: transcript in, lens out.
///
/// Three lanes, by how much a second of delay costs:
/// - Answers (Answer.swift): a question asked out loud, answered mid-sentence. Speculative —
///   fires on the partial transcript so the answer is up when they stop talking.
/// - Coach (Coach.swift): after each of the other person's turns, one call for definitions, the
///   next thing to say, and who they are. Half a second late is fine.
/// - Research: a deeper lookup the coach asks for now and then; seconds late is fine.
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
        /// What the wearer already knows; keeps obvious terms from being defined.
        var background = ""
        var answers: Model?
        var coach: Model?
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
        silent = false
        partial = text
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
    }

    /// A finished turn. `level` is its loudness in dB, for telling the wearer apart.
    func heard(line text: String, speaker: String?, level: Float? = nil) {
        let text = text.trimmed
        guard !text.isEmpty else { return }
        lastSpeech = Date()
        silent = false
        let mine = roles.isWearer(speaker)
        let (closed, open) = Talk.sentences(text)
        if closed.count > closedInTurn {
            for sentence in closed[closedInTurn...] where !command(sentence, mine: mine) {
                answerHeard(sentence, endpointed: true, mine: mine)
            }
        }
        if !open.isEmpty, !command(open, mine: mine) { answerHeard(open, endpointed: true, mine: mine) }
        partial = ""
        closedInTurn = 0
        compositor.hold(false, at: Date())

        if let speaker {
            let guessed = roles.wearer
            roles.heard(speaker, level: level)
            if !roles.sure, let wearer = roles.wearer, wearer != guessed {
                log(.roles, "You are probably speaker \(wearer)", detail: "your voice is louder at the mic; m if not")
            }
            // Someone introducing themselves settles who's who: our name means the wearer,
            // any other name means the other person.
            if !roles.sure, let name = Talk.introducedName(in: text) {
                if name.caseInsensitiveCompare(config.wearer) == .orderedSame {
                    roles.lock(speaker)
                    log(.roles, "You are speaker \(speaker)", detail: "you introduced yourself")
                } else {
                    roles.lock(them: speaker)
                    log(.roles, "\(name) is speaker \(speaker)", detail: "they introduced themselves")
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
        } else if let followup = lens.followup, roles.isWearer(speaker), !Talk.isBackchannel(text) {
            // An interjection is for the wearer's next turn. They've taken it; the moment passed.
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

    /// Face ID says who the other person is. Replaces the profile when it's someone new, keeping
    /// anything the conversation already taught us about the same person.
    func met(name: String, label: String?, facts: [String]) {
        guard !(them.recognised && them.name == name) else { return }
        let learned = Talk.same(them.name ?? "", name) ? them.facts : []
        them = Them(name: name, label: label, facts: facts + learned, recognised: true)
        log(.learned, "Talking to \(name)", detail: "face ID")
        compositor.setHeader(name)
        publish()
    }

    /// Start over for a new conversation.
    func reset() {
        answerTask?.cancel(); coachTask?.cancel(); researchTask?.cancel(); tickTask?.cancel(); silenceTask?.cancel()
        lines = []; turns = []; events = []; them = Them(); roles = Roles(); partial = ""; status = ""
        compositor.clear(); defined = []; researched = []; firedText = ""; generation += 1
        coachPending = false; coachBlockedUntil = nil; closedInTurn = 0
        publish()
    }

    // MARK: - Answers: the fast lane
    //
    // The whole design is about hiding latency inside the question rather than after it. A
    // question takes a human one to three seconds to say, and we know what it is well before the
    // last word: as soon as four words of a question clause exist we fire a speculative request on
    // the partial transcript, so the model's time-to-first-token overlaps the rest of the sentence.
    // Guards: refire only on real growth, at most `maxFires` times; ignore superseded fires
    // (generation counter); the model returns SKIP for anything personal, social or rhetorical.

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

        render()   // "…" on the lens right now, while they are still talking
        let context = transcript(last: 4)
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

    @ObservationIgnored private var lastCommand = ""

    /// "Lens, …" from the wearer (from anyone, while we don't know who that is) goes straight to
    /// the tools. True when `sentence` was a command, handled or deliberately dropped.
    private func command(_ sentence: String, mine: Bool) -> Bool {
        guard config.toolbox != nil, let request = Tools.command(in: sentence) else { return false }
        guard mine || !roles.known else { return true }   // the other person saying "lens" isn't asking us
        guard Talk.normalized(request) != Talk.normalized(lastCommand) else { return true }
        lastCommand = request
        toolRound(request, command: true)
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
        // "her company", "that place": the model resolves them from the conversation and what we know.
        let context = (them.summary.isEmpty ? "" : "About them: \(them.summary)\n") + transcript(last: 4)
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
    @ObservationIgnored private var silent = false
    @ObservationIgnored private var defined: [String] = []
    @ObservationIgnored private var researched: [String] = []

    /// Seconds of quiet that count as a lull worth rescuing.
    private static let lull: TimeInterval = 6
    /// Interjections are rationed: none until we know who's who and the conversation has had a few
    /// lines, then at most one a minute (sooner only to rescue a lull).
    private static let openingLines = 4
    private static let interjectionGap: TimeInterval = 60
    @ObservationIgnored private var lastInterjection = Date.distantPast

    private func interjectionAllowed(lull: Bool) -> Bool {
        guard roles.known else { return false }
        let since = Date().timeIntervalSince(lastInterjection)
        return lull ? lines.count >= 2 && since >= Self.interjectionGap / 2
                    : lines.count >= Self.openingLines && since >= Self.interjectionGap
    }

    /// One call at a time; anything heard meanwhile folds into one more call right after.
    private func coachSoon() {
        guard config.coach != nil else { return }
        if coachTask != nil {
            coachPending = true
            return
        }
        // Answers get first claim on a capped primary: the coach leaves three of the minute's calls.
        guard let coach = model(config.coach, blockedUntil: coachBlockedUntil, reserve: 3) else {
            coachPending = true   // rate-limited with no backup: blockCoach retries when it lifts
            return
        }
        let input = coachInput()
        let interject = input.interject
        let backup = config.backup
        lastCoach = Date()
        coachTask = Task { [weak self] in
            let started = Date()
            do {
                let advice: Coach.Advice
                do {
                    advice = try await Coach.ask(input, provider: coach.provider, key: coach.key, model: coach.model)
                } catch LLM.Failure.rateLimited(let wait) {
                    // Groq's free tier ran out: block it for a while and ask the backup right away.
                    self?.blockCoach(for: wait, falling: backup != nil && backup != coach)
                    guard let backup, backup != coach else { throw LLM.Failure.rateLimited(retryAfter: wait) }
                    advice = try await Coach.ask(input, provider: backup.provider, key: backup.key, model: backup.model)
                }
                self?.timings["coach", default: []].append(Int(Date().timeIntervalSince(started) * 1000))
                self?.apply(advice, interject: interject)
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

    private func coachInput() -> Coach.Input {
        // Networking conversations are short; the whole of one fits, so nothing said early is lost.
        var transcript = transcriptLines(last: 24)
        if !partial.isEmpty { transcript.append("\(predictedTag()) (still talking): \(partial)") }
        let lull = silent
        if silent {
            transcript.append("(silence, \(Int(Self.lull)) seconds)")
            silent = false
        }
        return Coach.Input(wearer: config.wearer, background: config.background, known: them.summary, defined: defined,
                           researched: researched, suggestion: lens.followup, interject: interjectionAllowed(lull: lull),
                           transcript: transcript)
    }

    private func apply(_ advice: Coach.Advice, interject: Bool) {
        let now = Date()
        let recent = Talk.normalized((lines.suffix(2).map(\.text) + [partial]).joined(separator: " "))
        // Only a term just said, of real substance, that the coach is sure of: "LO — likely
        // misheard LLM" (it was Elo) is worse than nothing.
        let unsure = ["misheard", "likely", "probably", "possibly", "unclear", "perhaps"]
        for term in advice.define where !defined.contains(where: { Talk.mentioned($0, in: Talk.normalized(term.term + " " + term.meaning)) })
            && term.term.count >= 3 && Talk.mentioned(term.term, in: recent)
            && !unsure.contains(where: term.meaning.lowercased().contains) {
            defined.append(term.term)
            nextCard += 1
            compositor.show(Card(kind: .definition, title: term.term, detail: term.meaning, id: nextCard), at: now)
            log(.define, term.term, detail: term.meaning)
        }
        switch advice.followup {
        case .keep:
            break
        case .clear:
            if lens.followup != nil {
                compositor.pin(nil, at: now)
                log(.followup, "cleared")
            }
        case .say(let text):
            // Advice is computed on the transcript as it was; if the wearer has since said it, it's stale.
            let said = lines.suffix(2).contains { roles.tag($0.speaker) != "THEM" && Talk.echoes($0.text, text) }
            if interject, !said, !Talk.speaksForWearer(text), Talk.normalized(text) != Talk.normalized(lens.followup ?? "") {
                lastInterjection = now
                compositor.pin(text, at: now)
                log(.followup, text)
            }
        }
        // A diarization label ("A") or the wearer's own name is never their name.
        if let name = advice.name, name.count > 2, name != them.name, !them.recognised,
           name.caseInsensitiveCompare(config.wearer) != .orderedSame {
            them.name = name
            log(.learned, "Name: \(name)")
        }
        if let label = advice.label, label != them.label, !them.recognised {
            them.label = label
            log(.learned, label)
        }
        compositor.setHeader(them.name)
        for fact in advice.facts where !(them.facts + [them.label ?? ""]).contains(where: { Talk.same($0, fact) }) {
            them.facts.append(fact)
            log(.learned, fact)
        }
        if let query = advice.research, !researched.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame }) {
            researched.append(query)
            research(query)
        }
        if status.hasPrefix("Coach") { status = "" }
        publish()
    }

    /// After a turn, if nobody says anything for a while and there is nothing pinned to say next,
    /// ask the coach for something. Silence is where an aid earns its keep.
    private func watchForSilence() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.lull))
            guard !Task.isCancelled, let self else { return }
            guard Date().timeIntervalSince(self.lastSpeech) >= Self.lull - 0.2, self.partial.isEmpty,
                  self.lens.followup == nil, !self.lines.isEmpty else { return }
            self.silent = true
            self.coachSoon()
        }
    }

    // MARK: - Research: the deep lane

    @ObservationIgnored private var researchTask: Task<Void, Never>?

    private func research(_ query: String) {
        guard let researcher = config.researcher else {
            log(.lookup, query, detail: "would look up (research is off)")
            return
        }
        guard researchTask == nil else {
            log(.lookup, query, detail: "skipped, another lookup is running")
            return
        }
        log(.lookup, query, detail: "looking up with \(researcher.name)")
        nextCard += 1
        let work = nextCard
        compositor.startWork(id: work, label: "Looking up " + query.split(separator: " ").prefix(5).joined(separator: " "), at: Date())
        publish()
        let context = transcript(last: 6)
        let started = Date()
        let condenser = config.backup ?? config.coach
        researchTask = Task { [weak self] in
            do {
                let finding = try await researcher.research(query, context: context)
                var card = ToolResult(title: String(finding.prefix(60)), detail: "", icon: "starCircleTriangleAi")
                if let condenser {
                    card = try await Tools.card(from: finding, about: query, provider: condenser.provider,
                                                key: condenser.key, model: condenser.model)
                }
                guard let self else { return }
                self.nextCard += 1
                self.compositor.show(Card(kind: .research, title: card.title, detail: card.detail, id: self.nextCard,
                                          icon: card.icon), at: Date())
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                self.timings["research", default: []].append(ms)
                self.log(.research, card.title, detail: "\(card.detail) · \(query) · \(ms) ms")
                self.publish()
            } catch {
                self?.log(.status, "Research failed: \(error.localizedDescription)")
            }
            self?.compositor.endWork(id: work)
            self?.publish()
            self?.researchTask = nil
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
        lines.filter { !$0.command }.suffix(n).map { "\(roles.tag($0.speaker)): \($0.text.count > 400 ? String($0.text.prefix(400)) + "…" : $0.text)" }
    }

    private func transcript(last n: Int) -> String {
        transcriptLines(last: n).joined(separator: "\n")
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

        // Research (tier 3): Fetch.ai ASI:One by default; OpenAI or Groq web search if asked for.
        var researcher: (any Researcher)?
        let researchKey = value("ResearchAPIKey")
        switch value("ResearchProvider")?.lowercased() {
        case "asi1", "fetch", "fetchai":
            if let key = researchKey { researcher = ASIOne(key: key, model: value("ResearchModel") ?? "asi1") }
        case "openai":
            if let key = researchKey { researcher = WebResearcher.openai(key: key) }
        case "groq":
            if let key = researchKey ?? (answerProvider == .groq ? answerKey : nil) { researcher = WebResearcher.groq(key: key) }
        default:
            break
        }
        let backupProvider = Provider(rawValue: value("BackupProvider")?.lowercased() ?? "") ?? .openai
        let backup = value("BackupAPIKey").map { Aid.Model(provider: backupProvider, key: $0, model: value("BackupModel") ?? backupProvider.model) }
        let answers = answerKey.map { Aid.Model(provider: answerProvider, key: $0, model: value("AnswerModel") ?? answerProvider.model) }
        // Cutting a finding down to a card wants a fast model with calls to spare: the backup.
        let condenser = (backup ?? answers).map { (provider: $0.provider, key: $0.key, model: $0.model) }
        // "37.7880,-122.4075": pretend to be there instead of asking Core Location (testing, or a
        // Mac command-line tool that can't get a fix).
        let test = (ProcessInfo.processInfo.environment["TEST_LOCATION"] ?? value("TestLocation"))?
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let pinned = test.flatMap { $0.count == 2 ? CLLocation(latitude: $0[0], longitude: $0[1]) : nil }
        return Aid.Config(
            wearer: wearer,
            background: value("WearerBackground") ?? "",
            answers: answers,
            coach: coachKey.map { Aid.Model(provider: coachProvider, key: $0, model: value("CoachModel") ?? coachProvider.model) },
            backup: backup,
            toolbox: value("Tools")?.lowercased() == "off" ? nil
                : DeviceTools(pinned: pinned, researcher: researcher, condenser: condenser),
            perMinute: value("AnswerPerMinute").flatMap { Int($0) },
            researcher: researcher)
    }
}
