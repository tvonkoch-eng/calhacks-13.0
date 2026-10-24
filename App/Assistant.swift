import Foundation
import Observation

/// One question we heard and what we did about it.
struct Turn: Identifiable {
    let id = UUID()
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

/// Ties the mic to the lens.
///
/// The whole design is about hiding latency inside the question rather than after it. A question
/// takes a human one to three seconds to say, and we know what it is well before the last word:
/// as soon as four words of a question clause exist we fire a speculative answer request on the
/// partial transcript. The model's time-to-first-token then overlaps the rest of the sentence, so
/// in the common case the answer is already on the lens when they stop talking.
///
/// Three guards keep that from being wasteful or wrong:
/// - Refire only when the question grew by `refireGrowth` words, and at most `maxFires` times.
/// - Ignore answers from a superseded fire (generation counter).
/// - The model returns SKIP for anything personal or social, and nothing ever reaches the lens.
@MainActor @Observable final class Assistant {
    var turns: [Turn] = []
    var transcript = ""
    var armed = false
    var note = ""

    @ObservationIgnored let listener = Listener()
    @ObservationIgnored weak var glasses: Glasses?

    /// Words of growth that justify spending a second request on the same question. One extra word
    /// is almost always the noun that completes a phrase we already guessed right; two is new content.
    private let refireGrowth = 2
    private let maxFires = 3
    private let refireInterval: TimeInterval = 0.4
    /// How long an answer stays on the lens once it stops changing.
    private let holdFor: TimeInterval = 14

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var firedText = ""
    @ObservationIgnored private var lastFireAt = Date.distantPast
    @ObservationIgnored private var answerTask: Task<Void, Never>?
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    init() {
        listener.onUpdate = { [weak self] text, endpointed in
            self?.heard(text, endpointed: endpointed)
        }
    }

    var status: String { armed ? listener.status : "Off" }
    var level: Float { listener.level }
    var current: Turn? { turns.first }

    func arm() async {
        guard !armed else { return }
        armed = true
        note = Answerer.configured ? "" : "No answer API key yet — add one to Secrets.xcconfig."
        await listener.start()
        if !listener.listening { armed = false }
    }

    func disarm() {
        armed = false
        listener.stop()
        answerTask?.cancel()
        clearTask?.cancel()
        reset()
        glasses?.showAnswer(nil)
    }

    // MARK: - The hot path

    private func heard(_ text: String, endpointed: Bool) {
        transcript = text
        guard let candidate = QuestionGate.candidate(in: text) else {
            if endpointed { commit(nil) }
            return
        }

        if endpointed {
            commit(candidate)
            return
        }

        guard candidate.confidence == .strong else { return }

        if firedText.isEmpty {
            fire(candidate.text)                       // first shot, mid-sentence
        } else if shouldRefire(candidate.text) {
            fire(candidate.text)                       // they said more than we guessed
        }
    }

    private func shouldRefire(_ text: String) -> Bool {
        guard let turn = turns.first, turn.fires < maxFires, text != firedText else { return false }
        guard Date().timeIntervalSince(lastFireAt) > refireInterval else { return false }
        let grew = words(text) - words(firedText)
        // The model already told us our guess was too fragmentary to answer; any new word is a
        // reason to try again.
        if turn.state == .skipped { return grew >= 1 }
        // Growth that merely extends what we asked is cheap to ignore until it is substantial; a
        // question that changed shape entirely means we guessed wrong and should start over.
        if text.hasPrefix(firedText) { return grew >= refireGrowth }
        return grew >= 1 || !firedText.hasPrefix(text)
    }

    /// The utterance ended. Lock in the real question and make sure that is what we answered.
    private func commit(_ candidate: Candidate?) {
        defer { firedText = "" }
        guard let candidate else {
            // Not a question after all (or they trailed off) — pull anything speculative back down.
            if let turn = turns.first, turn.live, turn.answer.isEmpty { drop() }
            return
        }
        guard var turn = turns.first, !firedText.isEmpty else {
            fire(candidate.text, committed: true)
            return
        }
        turn.committedAt = Date()
        turns[0] = turn
        let grew = words(candidate.text) - words(firedText)
        // Substantially more question than we guessed, or a guess the model refused: ask properly.
        // Otherwise let the in-flight answer stand — re-asking here costs the full round trip and
        // one trailing noun almost never changes the answer.
        let refused: Bool
        switch turn.state {
        case .skipped, .failed: refused = true
        default: refused = false
        }
        if candidate.text != firedText, grew >= refireGrowth || refused {
            fire(candidate.text, committed: true)
        } else {
            turns[0].question = candidate.text
            render()
        }
    }

    private func fire(_ question: String, committed: Bool = false) {
        answerTask?.cancel()
        clearTask?.cancel()
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
            var turn = Turn(question: question)
            turn.fires = 1
            if committed { turn.committedAt = Date() }
            turns.insert(turn, at: 0)
            if turns.count > 20 { turns.removeLast() }
        }

        // The local tier can finish before the network one starts.
        if let instant = Answerer.local(question) {
            update(generation) { $0.answer = instant; $0.state = .done; $0.shownAt = Date() }
            render()
            scheduleClear()
            return
        }

        render()   // puts "…" on the lens right now, while they are still talking

        answerTask = Task { [weak self] in
            do {
                var any = false
                for try await partial in Answerer.stream(question) {
                    guard !Task.isCancelled else { return }
                    any = true
                    self?.update(generation) {
                        if $0.shownAt == nil { $0.shownAt = Date() }
                        $0.answer = partial
                        $0.state = .answering
                    }
                    self?.render()
                }
                guard !Task.isCancelled else { return }
                self?.update(generation) { $0.state = any ? .done : .skipped }
                if any { self?.render() } else { self?.drop() }
                self?.scheduleClear()
            } catch {
                guard !Task.isCancelled else { return }
                self?.update(generation) { $0.state = .failed(error.localizedDescription) }
                self?.drop()
            }
        }
    }

    /// Only touch the turn if it still belongs to the fire that is talking.
    private func update(_ generation: Int, _ change: (inout Turn) -> Void) {
        guard generation == self.generation, var turn = turns.first else { return }
        change(&turn)
        turns[0] = turn
    }

    private func render() {
        guard let turn = turns.first else { return }
        switch turn.state {
        case .thinking:
            glasses?.showAnswer(AnswerCard(question: turn.question, answer: "", thinking: true))
        case .answering, .done:
            glasses?.showAnswer(AnswerCard(question: turn.question, answer: turn.answer,
                                           thinking: turn.state == .answering))
        case .skipped, .failed:
            glasses?.showAnswer(nil)
        }
    }

    private func drop() {
        glasses?.showAnswer(nil)
    }

    private func scheduleClear() {
        clearTask?.cancel()
        let generation = self.generation
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(holdFor))
            guard !Task.isCancelled, let self, generation == self.generation else { return }
            self.drop()
        }
    }

    private func reset() {
        firedText = ""
        transcript = ""
        generation += 1
    }

    private func words(_ s: String) -> Int {
        s.split(separator: " ").count
    }
}
