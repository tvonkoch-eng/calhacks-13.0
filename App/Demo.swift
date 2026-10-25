import Foundation
import Observation

/// Demo mode: one tip at the top of the lens, moved on by what actually happens (a contact made,
/// a name heard, Jarvis answering, an answer card), or by the phone's Next step button. Jarvis
/// stays off until its tip and the auto answers until theirs, so nothing gets ahead of the script.
@MainActor @Observable
final class Demo {
    enum Step: Int, CaseIterable {
        case look = 1, name, jarvis, talk, done
    }

    var on: Bool = (UserDefaults.standard.object(forKey: "DemoMode") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(on, forKey: "DemoMode"); changed?() }
    }
    private(set) var step: Step = .look
    /// The person met in the demo.
    private(set) var first: String?
    /// Redraw the lens.
    @ObservationIgnored var changed: (() -> Void)?

    /// The tip, or nil when demo mode is off or finished.
    var prompt: String? {
        guard on else { return nil }
        switch step {
        case .look: return "Tip: Look at someone to create a new contact!"
        case .name: return "Tip 2: Ask someone their name to get their information!"
        case .jarvis: return "Tip: Ask Jarvis any question!"
        case .talk: return "Tip: Talk to people to see how it works in convo!"
        case .done: return nil
        }
    }

    /// Jarvis is held back until its tip.
    var allowsJarvis: Bool { !on || step.rawValue >= Step.jarvis.rawValue }
    /// Auto answers, definitions and suggestions are held back until the last tip.
    var allowsAnswers: Bool { !on || step.rawValue >= Step.talk.rawValue }

    func reset() {
        step = .look
        first = nil
        changed?()
    }

    /// The phone's Next step: on to the next tip whatever happened.
    func skip() {
        guard on, let next = Step(rawValue: step.rawValue + 1) else { return }
        go(next)
    }

    /// Someone new became a contact, picture and all.
    func met(_ id: String) {
        guard on, step == .look else { return }
        first = id
        go(.name)
    }

    /// A name was filled in from the conversation, for whoever is in view.
    func named(_ id: String) {
        guard on, step == .name else { return }
        go(.jarvis)
    }

    /// Their profile got a bullet: no tip waits on it now.
    func learned(_ id: String) {}

    func jarvisAnswered() { if on, step == .jarvis { go(.talk) } }
    func answered() { if on, step == .talk { go(.done) } }

    #if targetEnvironment(simulator)
    /// What Next step stands in for in the simulator, per tip (`Assistant.demoDrive`).
    static let simulated: [Step: String] = [
        .look: "meet?photo=toby_01", .name: "name?n=Toby", .jarvis: "jarvis", .talk: "answer",
    ]
    #endif

    private func go(_ next: Step) {
        step = next
        changed?()
    }
}
