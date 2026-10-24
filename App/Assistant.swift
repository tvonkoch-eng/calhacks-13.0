import Foundation
import Observation

/// The phone's handle on the conversation assistant. All the logic lives in the shared engine
/// (Assist/Sources/AssistCore) and recognizer (Assist/Sources/AssistSpeech), which are compiled
/// into this app and also run on the Mac as `swift run assist`. This class only owns the mic task
/// and mirrors engine state for SwiftUI.
@MainActor @Observable final class Assistant {
    private(set) var turns: [Turn] = []
    private(set) var transcript = ""
    private(set) var armed = false
    private(set) var level: Float = 0
    private(set) var status = "Off"
    private(set) var note = ""

    /// The glasses lens; answers go here.
    @ObservationIgnored weak var glasses: Glasses? {
        didSet { engine.display = glasses }
    }

    @ObservationIgnored private let clock = SessionClock()
    @ObservationIgnored private let engine: Engine
    @ObservationIgnored private let answerer = Answerer.fromBundle()
    @ObservationIgnored private var work: Task<Void, Never>?

    init() {
        let clock = clock
        // Same event lines as the Mac tool, in the Xcode console.
        let log = EventLog(now: { clock.now() })
        engine = Engine(source: answerer, log: log, now: { clock.now() })
        engine.onChange = { [weak self] in self?.sync() }
    }

    var current: Turn? { turns.first }

    func arm() async {
        guard !armed else { return }
        armed = true
        note = answerer.key == nil ? "No answer API key: add ANSWER_API_KEY to Secrets.xcconfig." : ""
        let transcriber = Transcriber()
        transcriber.status = { [weak self] in self?.status = $0 }
        transcriber.level = { [weak self] value in Task { @MainActor in self?.level = value } }
        let engine = engine, clock = clock
        work = Task { [weak self] in
            do {
                try await transcriber.run(.microphone, onStart: { clock.zero = Date() }) { text, final, end in
                    engine.heard(text, final: final, audioEnd: end)
                }
            } catch {
                self?.status = error.localizedDescription
            }
            self?.armed = false
        }
    }

    func disarm() {
        work?.cancel()
        work = nil
        armed = false
        level = 0
        status = "Off"
        engine.reset()
    }

    private func sync() {
        turns = engine.turns
        transcript = engine.transcript
    }
}

extension Glasses: AnswerDisplay {
    func show(_ card: AnswerCard?) { showAnswer(card) }
}
