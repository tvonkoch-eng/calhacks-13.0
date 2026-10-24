import Foundation
import Observation

/// Ties the phone mic to the conversation aid, and the aid to the glasses.
///
/// All the thinking lives in `Aid` (App/Aid.swift), the same code `tools/live-mac.sh` runs on the
/// Mac: diarized lines in, a `LensView` out. This class only owns the plumbing: one `Listener`
/// (Muse realtime ASR), one `Aid`, the arm/disarm switch, and who the face side says THEM is.
@MainActor @Observable final class Assistant {
    var armed = false
    var note = ""

    @ObservationIgnored let listener = Listener()
    @ObservationIgnored weak var glasses: Glasses? {
        didSet { glasses?.onFacing = { [weak self] id in self?.facingChanged(id) } }
    }
    @ObservationIgnored weak var store: Store?
    let aid: Aid

    /// The person the face side last handed the aid, so a glance away and back doesn't re-seed it.
    @ObservationIgnored private var met: String?

    init() {
        let wearer = (Bundle.main.object(forInfoDictionaryKey: "WearerName") as? String)
            .flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 } ?? "Toby"
        aid = Aid(config: .fromBundle(wearer: wearer))
        listener.onPartial = { [weak self] text in self?.aid.heard(partial: text) }
        listener.onLine = { [weak self] text, speaker, level in self?.aid.heard(line: text, speaker: speaker, level: level) }
        aid.onLens = { [weak self] view in self?.glasses?.showAid(view) }
    }

    var status: String { armed ? (aid.status.isEmpty ? listener.status : aid.status) : "Off" }
    var level: Float { listener.level }
    var transcript: String { aid.partial }
    var current: Turn? { aid.current }

    func arm() async {
        guard !armed else { return }
        armed = true
        glasses?.aidArmed = true
        note = aid.config.answers == nil
            ? "No answer API key yet — add one to Secrets.xcconfig."
            : Listener.key == nil ? "No Muse key yet — add MUSE_API_KEY to Secrets.xcconfig." : ""
        // Whoever is in front of you right now is who you're about to talk to.
        if let id = glasses?.facing { facingChanged(id) }
        await listener.start()
        if !listener.listening {
            armed = false
            glasses?.aidArmed = false
        }
    }

    func disarm() {
        armed = false
        listener.stop()
        aid.reset()
        met = nil
        glasses?.aidArmed = false
        glasses?.showAid(LensView())
    }

    /// The wearer says the last line was theirs: fixes who's who when loudness guessed wrong.
    func lastLineWasMe() { aid.lastLineWasMe() }

    /// The face side's "who is THEM": the known face the wearer is looking at. Seeds the aid's
    /// profile of the other person, so the coach knows who they are before they introduce
    /// themselves. Looking away (nil) keeps the profile: people glance off mid-conversation.
    private func facingChanged(_ id: String?) {
        guard armed, let id, id != met, let person = store?.people.first(where: { $0.id == id }),
              person.name.split(separator: " ").first.map(String.init) != aid.config.wearer else { return }
        met = id
        aid.met(name: person.name, label: person.headline,
                facts: person.details.map(\.text))
    }
}
