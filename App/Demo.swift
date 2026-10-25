import Foundation
import Observation

/// Demo mode: one task line at the top of the lens telling the wearer what to do next, moved on
/// by what actually happens (a contact made, a name heard, a bullet learned, Jarvis answering, an
/// answer card), or by the phone's Next step button. Jarvis stays off until its task, and the
/// auto answers until theirs, so nothing gets ahead of the script.
@MainActor @Observable
final class Demo {
    enum Step: Int, CaseIterable {
        case look = 1, firstName, work, next, secondName, school, jarvis, question, done
    }

    var on: Bool = (UserDefaults.standard.object(forKey: "DemoMode") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(on, forKey: "DemoMode"); changed?() }
    }
    private(set) var step: Step = .look
    /// The two people met in the demo, in order.
    private(set) var first: String?
    private(set) var second: String?
    /// Redraw the lens.
    @ObservationIgnored var changed: (() -> Void)?

    /// The task line, or nil when demo mode is off or finished.
    var prompt: String? {
        guard on else { return nil }
        let task: String
        switch step {
        case .look: task = "Go up to the student and look at them"
        case .firstName: task = "Ask them their name"
        case .work: task = "Ask them what they do"
        case .next: task = "Meet the next person!"
        case .secondName: task = "Ask them their name!"
        case .school: task = "Ask them where they go to school!"
        case .jarvis: task = "Ask Jarvis where to get pizza nearby"
        case .question: task = "Wait for someone to ask you a question!"
        case .done: return nil
        }
        return "Task \(step.rawValue): \(task)"
    }

    /// Jarvis is held back until its task.
    var allowsJarvis: Bool { !on || step.rawValue >= Step.jarvis.rawValue }
    /// Auto answers, definitions and suggestions are held back until the last task.
    var allowsAnswers: Bool { !on || step.rawValue >= Step.question.rawValue }

    func reset() {
        step = .look
        first = nil
        second = nil
        changed?()
    }

    /// The phone's Next step: on to the next task whatever happened.
    func skip() {
        guard on, let next = Step(rawValue: step.rawValue + 1) else { return }
        go(next)
    }

    /// Someone new became a contact, picture and all.
    func met(_ id: String) {
        guard on else { return }
        if step == .look, first == nil {
            first = id
            go(.firstName)
        } else if step == .next, second == nil, id != first {
            second = id
            go(.secondName)
        }
    }

    /// Their name was filled in from the conversation.
    func named(_ id: String) {
        guard on else { return }
        if step == .firstName, id == first { go(.work) }
        if step == .secondName, id == second { go(.school) }
    }

    /// Their profile got a bullet (what they do, where they study).
    func learned(_ id: String) {
        guard on else { return }
        if step == .work, id == first { go(.next) }
        if step == .school, id == second { go(.jarvis) }
    }

    func jarvisAnswered() { if on, step == .jarvis { go(.question) } }
    func answered() { if on, step == .question { go(.done) } }

    #if targetEnvironment(simulator)
    /// What Next step stands in for in the simulator, per task (`Assistant.demoDrive`).
    static let simulated: [Step: String] = [
        .look: "meet?photo=avi", .firstName: "name?n=Avi", .work: "fact?t=Builds AR glasses at Cal Hacks",
        .next: "meet?photo=toby_01", .secondName: "name?n=Toby", .school: "fact?t=Studies CS at UC Berkeley",
        .jarvis: "jarvis", .question: "answer",
    ]
    #endif

    private func go(_ next: Step) {
        step = next
        changed?()
    }
}
