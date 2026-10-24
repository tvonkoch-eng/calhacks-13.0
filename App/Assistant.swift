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
    /// The wearer turned listening off; until they turn it on again, don't re-arm on our own.
    var mutedByUser = false

    @ObservationIgnored let listener = Listener()
    @ObservationIgnored weak var glasses: Glasses? {
        didSet {
            glasses?.onFacing = { [weak self] id in self?.facingChanged(id) }
            let listener = self.listener
            glasses?.audioSink.handler = { buffer in listener.feed(buffer) }
            glasses?.setStreamAudio(listener.mic == .glasses)
            glasses?.onStreamAudioLost = { [weak self] reason in
                guard let self else { return }
                self.mic = .phone
                self.note = reason == "micPermissionDenied"
                    ? "Glasses mic needs microphone access in Meta AI. Using the iPhone mic."
                    : "The glasses wouldn't stream audio. Using the iPhone mic."
            }
        }
    }
    /// Setting the roster names the wearer: the aid is rebuilt with the isMe person's first name.
    @ObservationIgnored weak var store: Store? {
        didSet {
            let me = store?.people.first(where: { $0.isMe == true })?.name.split(separator: " ").first.map(String.init)
            if let me, me != aid.config.wearer { aid = Self.makeAid(wearer: me) }
            crm?.rosterIDs = store?.people.filter { $0.isMe != true }.map(\.id) ?? []
        }
    }
    private(set) var aid: Aid {
        didSet {
            aid.onLens = { [weak self] view in self?.glasses?.showAid(view) }
            crm?.wearer = aid.config.wearer
            crm?.models = Self.recapModels(aid.config)
        }
    }
    /// The personal CRM keeps every conversation the aid hears (App/CRM.swift).
    @ObservationIgnored weak var crm: CRM? {
        didSet {
            guard let crm else { return }
            crm.wearer = aid.config.wearer
            crm.models = Self.recapModels(aid.config)
            crm.retag = { [weak self] label in self?.aid.tag(label) ?? label ?? "?" }
            crm.heardAboutThem = { [weak self] in (self?.aid.them.name, self?.aid.them.facts ?? []) }
            crm.roster = { [weak self] id in
                self?.store?.people.first(where: { $0.id == id }).map { CRM.Known(name: $0.name, about: $0.headline) }
            }
            crm.rosterIDs = store?.people.filter { $0.isMe != true }.map(\.id) ?? []
            // The card already has the name: under it, the label and the line from last time.
            LensCards.recall = { [weak crm] id in
                MainActor.assumeIsolated {
                    guard let crm else { return nil }
                    let parts = [crm.label(id), crm.lastLine(id)].compactMap { $0 }
                    return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
                }
            }
        }
    }

    /// A recap is one call per conversation and quality matters more than speed: the coach's
    /// model first, then the backup (a 429 on the coach is common), then the answer model.
    private static func recapModels(_ config: Aid.Config) -> [Aid.Model] {
        var models: [Aid.Model] = []
        for model in [config.coach, config.backup, config.answers].compactMap(\.self) where !models.contains(model) {
            models.append(model)
        }
        return models
    }

    /// The person the face side last handed the aid, so a glance away and back doesn't re-seed it.
    @ObservationIgnored private var met: String?

    init() {
        // Until the roster is in, the bundle's WearerName (WEARER_NAME), else Toby.
        let wearer = (Bundle.main.object(forInfoDictionaryKey: "WearerName") as? String)
            .flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 } ?? "Toby"
        aid = Self.makeAid(wearer: wearer)
        // New key on purpose: the glasses default of the last build shouldn't carry over.
        listener.mic = Listener.Mic(rawValue: UserDefaults.standard.string(forKey: "mic") ?? "") ?? .phone
        listener.onLog = { SpeedLog.record($0) }
        listener.onPartial = { [weak self] text in self?.aid.heard(partial: text) }
        listener.onLine = { [weak self] text, speaker, level in
            guard let self else { return }
            self.aid.heard(line: text, speaker: speaker, level: level)
            self.crm?.heard(text, speaker: speaker, command: Tools.command(in: text) != nil)
        }
        aid.onLens = { [weak self] view in self?.glasses?.showAid(view) }
    }

    private static func makeAid(wearer: String) -> Aid { Aid(config: .fromBundle(wearer: wearer)) }

    var status: String { armed ? (aid.status.isEmpty ? listener.status : aid.status) : "Off" }
    var level: Float { listener.level }
    var transcript: String { aid.partial }
    var current: Turn? { aid.current }

    func arm() async {
        guard !armed else { return }
        armed = true
        // A new conversation starts clean; the last one stays readable on the phone until then.
        aid.reset()
        met = nil
        glasses?.aidArmed = true
        note = aid.config.answers == nil
            ? "No answer API key yet — add one to Secrets.xcconfig."
            : Listener.key == nil ? "No Muse key yet — add MUSE_API_KEY to Secrets.xcconfig." : ""
        // Whoever is in front of you right now is who you're about to talk to.
        if let id = glasses?.facing { facingChanged(id) }
        // Names of people likely here, so speech recognition spells them right.
        if let crm { listener.keywords = crm.keywords(roster: store?.people.map(\.name) ?? []) }
        await listener.start()
        if !listener.listening {
            armed = false
            glasses?.aidArmed = false
        }
    }

    func disarm() {
        armed = false
        // Mic off ends the conversation: save it and recap it now, not two minutes from now.
        crm?.tick(force: true)
        listener.stop()
        glasses?.aidArmed = false
        glasses?.showAid(LensView())
    }

    /// The mic pill: off is a choice that sticks; on is the default.
    func toggle() async {
        if armed { mutedByUser = true; disarm() } else { mutedByUser = false; await arm() }
    }

    /// Listening is on unless the wearer turned it off: called at launch and on every return to
    /// the foreground, so a failed start (no route yet, permission sheet) gets another go.
    func ensureListening() async {
        guard !armed, !mutedByUser else { return }
        await arm()
    }

    /// iPhone mic (default) or the glasses'. Remembered across launches; switches live.
    var mic: Listener.Mic {
        get { listener.mic }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "mic")
            listener.use(newValue)
            glasses?.setStreamAudio(newValue == .glasses)
        }
    }

    /// What it heard last, for the phone: the turn in progress, else the last finished line.
    var heard: (tag: String, text: String)? {
        if !aid.partial.isEmpty { return ("…", aid.partial) }
        guard let line = aid.lines.last else { return nil }
        return (aid.tag(line.speaker), line.text)
    }

    /// The wearer says the last line was theirs: fixes who's who when loudness guessed wrong.
    func lastLineWasMe() { aid.lastLineWasMe() }

    /// The face side's "who is THEM": the known face the wearer is looking at. Seeds the aid's
    /// profile of the other person, so the coach knows who they are before they introduce
    /// themselves. Looking away (nil) keeps the profile: people glance off mid-conversation.
    private func facingChanged(_ id: String?) {
        if id == nil || store?.contacts.first(where: { $0.id == id })?.isMe != true { crm?.facing(id) }
        guard armed, let id, id != met, let person = store?.contacts.first(where: { $0.id == id }),
              person.name.split(separator: " ").first.map(String.init) != aid.config.wearer else { return }
        met = id
        aid.met(name: person.name, label: person.headline,
                facts: person.details.map(\.text) + (crm?.record(id).briefing ?? []))
    }
}
