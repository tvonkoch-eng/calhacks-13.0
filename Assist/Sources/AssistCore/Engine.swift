import Foundation

/// What the lens shows: the answer so far, plus enough of the question to make it legible.
public struct AnswerCard: Equatable, Sendable {
    public let question: String
    public let answer: String
    public let thinking: Bool

    public init(question: String, answer: String, thinking: Bool) {
        self.question = question
        self.answer = answer
        self.thinking = thinking
    }

    public var headline: String { answer.isEmpty ? "\u{2026}" : answer }

    public var echo: String {
        let words = question.split(separator: " ")
        guard words.count > 7 else { return question }
        return words.prefix(7).joined(separator: " ") + "\u{2026}"
    }
}

/// Wherever answers are shown: the glasses lens, a phone view, a terminal.
@MainActor public protocol AnswerDisplay: AnyObject {
    func show(_ card: AnswerCard?)
}

/// One question we heard and what we did about it.
public struct Turn: Identifiable, Sendable {
    public let id = UUID()
    /// The question clause we asked the model (fillers and lead-ins stripped).
    public var question: String
    /// Raw transcript it came from.
    public var heard: String
    public var answer = ""
    public var state: State = .thinking
    public var fires = 0
    /// Engine clock (seconds since listening started).
    public var lastFiredAt: Double = 0
    public var firstTokenAfter: Double?
    public var shownAt: Double?
    /// When the speaker finished the question, in the same clock.
    public var questionEnd: Double?
    public var log: [String] = []

    public enum State: Equatable, Sendable {
        case thinking, answering, done
        case personal      // model said SKIP
        case incomplete    // model said WAIT
        case abandoned     // the sentence turned out not to be a question
        case failed(String)
    }

    /// Seconds the answer was on screen before the speaker finished. Negative = after.
    public var lead: Double? {
        guard let shownAt, let questionEnd else { return nil }
        return questionEnd - shownAt
    }

    public var live: Bool { state == .thinking || state == .answering }
}

/// Turns a live transcript into answers on a display, as early as possible.
///
/// The latency has to land inside the question, not after it. A question takes one to three
/// seconds to say and is usually recognisable before the last word, so as soon as the gate calls
/// a partial transcript a strong question we fire the answer request on it. The model's
/// time-to-first-token then overlaps the end of the sentence.
///
/// Guards:
/// - Refire only when the question grew by `refireGrowth` words, changed shape, or the model said
///   WAIT; at most `maxFires` times per question. A generation counter drops superseded answers.
/// - A sentence the recognizer closes mid-phrase ("How tall is the.") is carried into the next
///   segment instead of being committed, so a pause mid-question does not split it in two.
/// - The model, not the regex, decides what is personal (SKIP); nothing is shown for those.
@MainActor public final class Engine {
    public private(set) var turns: [Turn] = []
    public private(set) var transcript = ""
    public weak var display: AnswerDisplay?
    public var onChange: (() -> Void)?
    /// A sentence was closed and dealt with: (final text, sentences said just before, turn it
    /// produced if any). For grading every sentence, including questions the gate missed.
    public var onSentence: ((_ text: String, _ before: [String], _ turn: UUID?) -> Void)?
    public let log: EventLog

    public var refireGrowth = 2
    public var maxFires = 3
    public var refireInterval = 0.4
    public var holdFor = 14.0
    /// No new hypothesis for this long means the last word is done being spoken.
    public var settleAfter = 0.15
    /// How long a mid-phrase sentence waits for its second half.
    public var carryWindow = 1.6

    private let source: AnswerSource
    private let now: () -> Double
    private var generation = 0
    private var currentTurn: UUID?
    private var firedText = ""
    private var lastFireAt = -Double.infinity
    private var carry = ""
    /// How the held sentence joins the next one. A held half-question ("How tall is the") reads
    /// straight on; a held statement ("You don't feel like that") gets a comma so a question that
    /// follows it ("Who won last year's Cal Hacks?") is still found as its own clause.
    private var carryJoin = " "
    /// Recent closed sentences, sent along so "how far is it from Munich" knows what "it" is.
    private var history: [String] = []
    private var lastGate = ""
    private var lastCard: AnswerCard??
    private var answerTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var carryTask: Task<Void, Never>?

    public init(source: AnswerSource, log: EventLog, now: @escaping () -> Double) {
        self.source = source
        self.log = log
        self.now = now
    }

    public var current: Turn? { turns.first }

    /// Feed every recognizer update. `final` means the recognizer closed the sentence.
    /// `audioEnd` is where that text ends in the audio, in the engine clock, when known.
    public func heard(_ raw: String, final: Bool, audioEnd: Double? = nil) {
        var text = raw.trimmed
        guard !text.isEmpty else { return }
        settleTask?.cancel()
        var joined = false
        if !carry.isEmpty {
            carryTask?.cancel()
            text = carry + carryJoin + text
            if final { carry = ""; joined = true }
        }
        transcript = text
        if final {
            log(.final, "\"\(text)\"", ["audioEnd": audioEnd.map { String(format: "%.3f", $0) } ?? ""])
            commit(text, audioEnd: audioEnd, joined: joined)
        } else {
            log(.hear, "\"\(text)\"")
            consider(text, settled: false)
            settleTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.settleAfter))
                guard !Task.isCancelled, self.transcript == text else { return }
                self.consider(text, settled: true)
            }
        }
        onChange?()
    }

    /// Stop everything and clear the display.
    public func reset() {
        for task in [answerTask, clearTask, settleTask, carryTask] { task?.cancel() }
        generation += 1
        currentTurn = nil
        firedText = ""
        carry = ""
        transcript = ""
        show(nil)
        onChange?()
    }

    // MARK: - Deciding when to ask

    private func consider(_ text: String, settled: Bool) {
        let candidate = QuestionGate.candidate(in: text, settled: settled)
        let verdict = candidate.map { "\($0.confidence == .strong ? "strong" : "weak") \"\($0.text)\"" } ?? "not a question"
        if verdict != lastGate {
            lastGate = verdict
            log(.gate, verdict + (settled ? " (settled)" : ""))
        }
        guard let candidate, candidate.confidence == .strong else { return }
        if currentTurn == nil {
            fire(candidate.text, heard: text, reason: "first strong partial")
        } else if let reason = refireReason(candidate.text) {
            fire(candidate.text, heard: text, reason: reason)
        }
    }

    private func refireReason(_ text: String) -> String? {
        guard let turn = turnIndex.map({ turns[$0] }), turn.fires < maxFires, text != firedText else { return nil }
        guard now() - lastFireAt > refireInterval else { return nil }
        let grew = words(text) - words(firedText)
        // +2, not +1: each WAIT costs a request from a daily cap, and one more word rarely
        // completes a question ("how many miles" → "how many miles away" was WAIT four times).
        if turn.state == .incomplete { return grew >= 2 ? "model said WAIT, now +\(grew) words" : nil }
        if text.hasPrefix(firedText) { return grew >= refireGrowth ? "question grew +\(grew) words" : nil }
        if firedText.hasPrefix(text) { return nil }   // recognizer revised backwards; wait
        return "question changed"
    }

    /// The recognizer closed a sentence. Make sure what we answered is what was asked.
    private func commit(_ text: String, audioEnd: Double?, joined: Bool = false) {
        lastGate = ""
        let candidate = QuestionGate.candidate(in: text, settled: true)

        // "How tall is the." / "How many..." / "all data that I can." — the recognizer closed the
        // sentence at a pause mid-thought. Hold it and glue on whatever comes next, so a question
        // is never asked (or missed) in pieces. Bounded so a rambling run still gets committed.
        let midQuestion = candidate?.unfinished == true
        let midThought = QuestionGate.endsMidThought(text)
        // A statement already joined once is committed, not held again: live, holds chained three
        // or four sentences together ("Can you hear this, But then…, What is the capital…").
        if midQuestion || (midThought && !joined), carry.isEmpty, words(text) < 40 {
            carry = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?… ").union(.whitespaces))
            carryJoin = midQuestion ? " " : ", "
            log(.carry, "\"\(carry)\" ends mid-\(midQuestion ? "question" : "thought"); waiting \(carryWindow)s for the rest")
            carryTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.carryWindow))
                guard !Task.isCancelled, !self.carry.isEmpty else { return }
                let held = self.carry
                self.carry = ""
                self.log(.carry, "nothing followed; committing \"\(held)\" as is")
                self.finish(held, candidate: QuestionGate.candidate(in: held, settled: true), audioEnd: audioEnd)
            }
            return
        }
        finish(text, candidate: candidate, audioEnd: audioEnd)
    }

    private func finish(_ text: String, candidate: Candidate?, audioEnd: Double?) {
        defer {
            onSentence?(text, history, currentTurn)
            currentTurn = nil
            firedText = ""
            history.append(text)
            if history.count > 3 { history.removeFirst() }
            onChange?()
        }
        let end = audioEnd ?? now()

        guard let candidate else {
            if let i = turnIndex, turns[i].answer.isEmpty, turns[i].live || turns[i].state == .incomplete {
                answerTask?.cancel()
                generation += 1
                turns[i].state = .abandoned
                log(.abandon, "\"\(text)\" is not a question; dropped the early guess \"\(turns[i].question)\"")
                show(nil)
            } else if let prev = turns.first, prev.answer.isEmpty,
                      [.incomplete, .personal, .thinking].contains(prev.state),
                      now() - prev.lastFiredAt < 2.5, (2...4).contains(words(text)),
                      prev.question.split(separator: " ").count <= 5 {
                // "Who painted them?" + "Mona Lisa.": the recognizer closed a short question at a
                // pause (and often misheard the word before it). The question went unanswered and a
                // short fragment followed right away, so it is the rest of the question.
                currentTurn = prev.id
                let joined = prev.question + " " + QuestionGate.plain(text)
                fire(joined, heard: prev.heard + " " + text, reason: "short follow-up completes the unanswered question", settled: true)
                turns[0].questionEnd = end
            } else {
                log(.commit, "not a question")
            }
            return
        }

        guard let i = turnIndex else {
            fire(candidate.text, heard: text, reason: "sentence ended (no early fire)", settled: true)
            if let j = turnIndex { turns[j].questionEnd = end }
            return
        }
        turns[i].questionEnd = end
        turns[i].heard = text
        let grew = words(candidate.text) - words(firedText)
        let state = turns[i].state
        var reason: String?
        if state == .incomplete {
            reason = "model said WAIT on the partial; asking again now the sentence is complete"
        } else if candidate.text != firedText {
            switch state {
            case .incomplete: reason = "model said WAIT on the partial"
            case .failed: reason = "partial request failed"
            case .personal: reason = "model said SKIP on the partial; asking with the full sentence"
            default:
                let added = candidate.text.split(separator: " ").dropFirst(words(firedText))
                let early = firedText.split(separator: " "), late = candidate.text.split(separator: " ")
                // Words before the last one changed: Whisper corrected the transcript, so the early
                // guess answered a different question ("use with fraud" → "use with Groq").
                var changed = early.dropLast().enumerated().filter { $0.offset >= late.count || late[$0.offset] != $0.element }.count
                // Only spacing changed ("cal hacks" → "calhacks"): same question.
                if late.joined().hasPrefix(early.dropLast().joined()) { changed = 0 }
                if changed >= 1 {
                    reason = "final transcript differs from the early guess (\(changed) word\(changed == 1 ? "" : "s"))"
                } else if grew >= refireGrowth {
                    reason = "final question is +\(grew) words longer"
                } else if added.contains(where: { $0.contains(where: \.isNumber) }) {
                    reason = "final question added a number"
                } else if let piece = firedText.split(separator: " ").last,
                          !candidate.text.split(separator: " ").contains(piece) {
                    reason = "early guess ended on a word fragment \"\(piece)\""
                } else if source.local(candidate.text) != nil {
                    reason = "final question has an instant answer"
                }
            }
        }
        if let reason {
            fire(candidate.text, heard: text, reason: reason, settled: true)
            if let j = turnIndex { turns[j].questionEnd = end }
        } else {
            log(.commit, "keeping answer for \"\(firedText)\" (final: \"\(candidate.text)\")")
            turns[i].question = candidate.text
        }
    }

    // MARK: - Asking

    private var turnIndex: Int? {
        guard let currentTurn else { return nil }
        return turns.firstIndex { $0.id == currentTurn }
    }

    private func fire(_ question: String, heard: String, reason: String, settled: Bool = false) {
        answerTask?.cancel()
        clearTask?.cancel()
        generation += 1
        let generation = self.generation
        firedText = question
        lastFireAt = now()

        let i: Int
        if let existing = turnIndex {
            i = existing
        } else {
            let turn = Turn(question: question, heard: heard)
            turns.insert(turn, at: 0)
            if turns.count > 50 { turns.removeLast() }
            currentTurn = turn.id
            i = 0
        }
        turns[i].question = question
        turns[i].heard = heard
        turns[i].fires += 1
        turns[i].state = .thinking
        turns[i].lastFiredAt = lastFireAt
        log(.fire, "#\(turns[i].fires) \"\(question)\"  (\(reason))")

        if let instant = source.local(question) {
            update(generation) {
                $0.answer = instant
                $0.state = .done
                $0.firstTokenAfter = 0
                $0.shownAt = $0.shownAt ?? self.now()
            }
            log(.answer, "\"\(instant)\"  (local, no network)")
            render()
            scheduleClear()
            return
        }
        render()

        let firedAt = lastFireAt
        let context = history.joined(separator: " ").split(separator: " ").suffix(40).joined(separator: " ")
        answerTask = Task { [weak self, source] in
            do {
                for try await event in source.stream(question, context: context, settled: settled) {
                    guard let self, !Task.isCancelled, generation == self.generation else { return }
                    switch event {
                    case .text(let text):
                        let t = self.now()
                        self.update(generation) {
                            if $0.state != .answering {
                                $0.firstTokenAfter = t - firedAt
                                self.log(.token, String(format: "first words after %.0f ms: \"%@\"", (t - firedAt) * 1000, text))
                            }
                            if $0.shownAt == nil { $0.shownAt = t }
                            $0.answer = text
                            $0.state = .answering
                        }
                    case .personal:
                        self.update(generation) { $0.state = .personal }
                        self.log(.personal, "model: SKIP for \"\(question)\"")
                    case .incomplete:
                        self.update(generation) { $0.state = .incomplete }
                        self.log(.incomplete, "model: WAIT for \"\(question)\" (too cut off)")
                        // The WAIT landed after the sentence was already closed (the request was
                        // still in flight at commit, so commit kept it). Nothing else will re-ask,
                        // so ask again now as a finished question, where WAIT is not allowed.
                        if !settled, self.currentTurn == nil, let turn = self.turns.first, turn.questionEnd != nil {
                            self.currentTurn = turn.id
                            self.fire(turn.question, heard: turn.heard,
                                      reason: "model said WAIT after the sentence ended", settled: true)
                            self.currentTurn = nil
                            return
                        }
                    }
                    self.render()
                }
                guard let self, !Task.isCancelled, generation == self.generation else { return }
                if let i = self.turnIndexFor(generation), self.turns[i].state == .answering {
                    self.turns[i].state = .done
                    self.log(.answer, String(format: "\"%@\"  (%.0f ms total)", self.turns[i].answer, (self.now() - firedAt) * 1000))
                    self.render()
                    self.scheduleClear()
                }
                self.onChange?()
            } catch {
                guard let self, !Task.isCancelled, generation == self.generation else { return }
                self.update(generation) { $0.state = .failed(error.localizedDescription) }
                self.log(.error, "answer request failed: \(error.localizedDescription)")
                self.render()
            }
        }
    }

    /// Only the newest fire may touch the turn.
    private func update(_ generation: Int, _ change: (inout Turn) -> Void) {
        guard let i = turnIndexFor(generation) else { return }
        change(&turns[i])
        onChange?()
    }

    private func turnIndexFor(_ generation: Int) -> Int? {
        guard generation == self.generation else { return nil }
        // The turn being answered is the newest one, even after the utterance was committed.
        return turns.isEmpty ? nil : 0
    }

    // MARK: - Display

    private func render() {
        guard let turn = turns.first else { return show(nil) }
        switch turn.state {
        case .thinking, .incomplete:
            show(AnswerCard(question: turn.question, answer: turn.answer, thinking: true))
        case .answering:
            show(AnswerCard(question: turn.question, answer: turn.answer, thinking: true))
        case .done:
            show(AnswerCard(question: turn.question, answer: turn.answer, thinking: false))
        case .personal, .abandoned, .failed:
            show(nil)
        }
    }

    /// Put a side note on the lens, unless an answer is in progress or was just shown: answers
    /// to questions always win. Returns whether it went up.
    @discardableResult
    public func showAside(_ note: String, topic: String) -> Bool {
        if let t = turns.first {
            if t.live { return false }
            // Give an answer a few seconds to be read; after that a note may replace it.
            if t.state == .done, now() - t.lastFiredAt < 6 { return false }
        }
        log(.aside, "\(note)   · \(topic)")
        show(AnswerCard(question: "\u{24D8} " + topic, answer: note, thinking: false))
        scheduleClear()
        return true
    }

    private func show(_ card: AnswerCard?) {
        if let lastCard, lastCard == card { return }
        lastCard = .some(card)
        if let card {
            log(.lens, "\(card.headline)   · \(card.echo)\(card.thinking ? "" : "  ✓")")
        } else {
            log(.lens, "(cleared)")
        }
        display?.show(card)
    }

    private func scheduleClear() {
        clearTask?.cancel()
        let generation = self.generation
        clearTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.holdFor))
            guard !Task.isCancelled, generation == self.generation else { return }
            self.show(nil)
        }
    }

    private func words(_ s: String) -> Int { s.split(separator: " ").count }
}
