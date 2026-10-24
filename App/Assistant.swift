import Foundation
import Observation

/// Ties the phone mic to the conversation aid, and the aid to the glasses.
///
/// All the thinking lives in `Aid` (App/Aid.swift), the same code `tools/live-mac.sh` runs on the
/// Mac: diarized lines in, a `LensView` out. This class only owns the plumbing: one `Listener`
/// (Muse realtime ASR), one `Aid`, the arm/disarm switch, who said each line (`Speakers`), and
/// who is in the conversation (the group the lens shows).
@MainActor @Observable final class Assistant {
    var armed = false
    var note = ""
    /// The wearer turned listening off; until they turn it on again, don't re-arm on our own.
    var mutedByUser = false
    /// Everyone in the conversation, in the order they joined, the one talking marked.
    private(set) var members: [Member] = []
    /// The wearer has the floor (the glasses' own mic hears them).
    private(set) var meSpeaking = false
    /// Why the last line was given to whoever it was, for the phone ("glasses heard you (80%)").
    private(set) var lastWhy = ""

    @ObservationIgnored let listener = Listener()
    @ObservationIgnored weak var glasses: Glasses? {
        didSet {
            glasses?.onFacing = { [weak self] id in self?.facingChanged(id) }
            glasses?.onSeen = { [weak self] ids in self?.seen(ids) }
            glasses?.onOwnSpeech = { [weak self] text, _ in self?.ownSpeech(text) }
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
            speakers.wearer = aid.config.wearer
            speakers.roster = roster()
        }
    }
    private(set) var aid: Aid {
        didSet { wire(aid) }
    }

    /// Lens to the glasses; every aid event into speed.jsonl, so "why didn't it answer?" has an
    /// answer afterwards (the line with its speaker, the answer or the skip, rate limits).
    private func wire(_ aid: Aid) {
        aid.onLens = { [weak self] view in self?.glasses?.showAid(view) }
        aid.onEvent = { [weak self] event in
            var entry: [String: Any] = ["event": "aid", "kind": "\(event.kind)", "text": String(event.text.prefix(160))]
            if !event.detail.isEmpty { entry["detail"] = String(event.detail.prefix(160)) }
            if let speaker = event.speaker { entry["speaker"] = speaker; entry["tag"] = self?.name(for: speaker) ?? speaker }
            SpeedLog.record(entry)
        }
        // Speakers knows who's talking better than turn alternation can: with three people, the
        // turn after Avi's is as likely Mira's as the wearer's. No signal means "not the wearer",
        // so their questions still get answered.
        aid.liveWearer = { [weak self] in self?.speakers.wearerTalking() ?? false }
        aid.nameFor = { [weak self] label in
            guard let self, label.hasPrefix("p:"), let person = self.person(String(label.dropFirst(2))) else { return nil }
            return self.firstName(person.name)
        }
    }

    /// The person the aid's profile is about, so a glance away and back doesn't re-seed it.
    @ObservationIgnored private var met: String?
    @ObservationIgnored private var speakers = Speakers(wearer: "Toby")
    /// When the turn in progress started (its first partial), for lining it up with the glasses'
    /// own transcription and with where the wearer was looking.
    @ObservationIgnored private var turnStarted: Date?
    /// The Muse label each resolved label last came from, for "That was me".
    @ObservationIgnored private var museLabel: [String: String] = [:]
    @ObservationIgnored private var lastPersonLine = Date.distantPast
    @ObservationIgnored private var tick: Task<Void, Never>?

    init() {
        // Until the roster is in, the bundle's WearerName (WEARER_NAME), else Toby.
        let wearer = (Bundle.main.object(forInfoDictionaryKey: "WearerName") as? String)
            .flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 } ?? "Toby"
        aid = Self.makeAid(wearer: wearer)
        speakers = Speakers(wearer: wearer)
        // New key on purpose: the glasses default of the last build shouldn't carry over.
        // Always the iPhone mic at launch: streaming the glasses' mic through the camera stream
        // kills both video and audio (DAT 1.0.1). The menu can still pick Glasses for one session.
        listener.mic = .phone
        UserDefaults.standard.set(Listener.Mic.phone.rawValue, forKey: "mic")
        listener.onLog = { SpeedLog.record($0) }
        listener.onPartial = { [weak self] text in
            guard let self else { return }
            if self.turnStarted == nil { self.turnStarted = Date().addingTimeInterval(-0.5) }
            self.aid.heard(partial: text)
        }
        listener.onLine = { [weak self] text, speaker, _ in self?.line(text, label: speaker) }
        wire(aid)
    }

    /// Tuning knobs, no rebuild: explicit questions only, and the coach on. The coach was off after
    /// it misfired in a real conversation about our own product (it researched "Meta AR glasses
    /// frame rate" and named THEM after someone mentioned); both are gone by construction now: no
    /// coach lookups, names only from introductions or face ID, suggestions only in a lull, on
    /// "Lens, what should I ask?" or when a face is recognised. `aidCoach` false turns it off live.
    private static func makeAid(wearer: String) -> Aid {
        var config = Aid.Config.fromBundle(wearer: wearer)
        config.explicitOnly = Tuning.bool("aidExplicitOnly", true)
        if !Tuning.bool("aidCoach", true) { config.coach = nil }
        return Aid(config: config)
    }

    var status: String { armed ? (aid.status.isEmpty ? listener.status : aid.status) : "Off" }
    var level: Float { listener.level }
    var transcript: String { aid.partial }
    var current: Turn? { aid.current }
    /// The glasses' own transcription: "On", "Off", or why not.
    var ownVoice: String { glasses?.ownVoice ?? "Off" }
    /// How the wearer is being told apart, for the phone: nil when nothing beyond the defaults.
    var voiceID: (label: String, working: Bool)? {
        if mic == .glasses {
            let arriving = !listener.input.contains("not arriving")
            return (arriving ? "Voice ID · glasses mic" : "Glasses mic not arriving", arriving)
        }
        if ownVoice == "On" { return ("Voice ID", true) }
        return ownVoice == "Off" ? nil : (ownVoice, false)
    }

    func arm() async {
        guard !armed else { return }
        armed = true
        // A new conversation starts clean; the last one stays readable on the phone until then.
        aid.reset()
        aid.assume(wearer: Self.me)
        speakers = Speakers(wearer: aid.config.wearer)
        speakers.roster = roster()
        met = nil
        museLabel = [:]
        joined = [:]
        speaking = nil
        meSpeaking = false
        members = []
        glasses?.setGroup([], meSpeaking: false)
        refreshGroup()
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
            return
        }
        tick?.cancel()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.refreshGroup()
            }
        }
    }

    func disarm() {
        armed = false
        tick?.cancel()
        tick = nil
        listener.stop()
        glasses?.aidArmed = false
        glasses?.setGroup([], meSpeaking: false)
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
        if !aid.partial.isEmpty { return (meSpeaking ? "YOU" : "…", aid.partial) }
        guard let line = aid.lines.last else { return nil }
        return (name(for: line.speaker), line.text)
    }

    // MARK: - Who said it

    /// The aid's label for the wearer. Other people are `p:<person id>`, or Muse's own label while
    /// nobody knows who that voice is.
    static let me = "me"

    /// How a resolved label reads on the phone: YOU, a first name, or THEM.
    func name(for label: String?) -> String {
        guard let label else { return "?" }
        if label == Self.me { return "YOU" }
        if label.hasPrefix("p:"), let person = person(String(label.dropFirst(2))) {
            return firstName(person.name).uppercased()
        }
        return "THEM"
    }

    /// The wearer says the last line was theirs: fixes who's who from here on.
    func lastLineWasMe() {
        guard let label = aid.lines.last(where: { $0.speaker != nil })?.speaker else { return }
        markMe(label)
    }

    /// "That was me" on a line: this voice is the wearer's from now on.
    func markMe(_ label: String) {
        guard label != Self.me else { return }
        let muse = museLabel[label] ?? label
        speakers.markMe(muse)
        SpeedLog.record(["event": "speaker", "markMe": muse, "was": label])
    }

    private func line(_ text: String, label muse: String?) {
        let end = Date()
        let start = turnStarted ?? end.addingTimeInterval(-max(1, Double(text.split(separator: " ").count) * 0.35))
        turnStarted = nil
        let match = speakers.ownVoiceMatch(text, start: start, end: end)
        // Glasses mic on: how much louder this line was there than at the phone underneath.
        let gap = listener.mic == .glasses ? listener.meter.gap(from: start, to: end) : nil
        let verdict = speakers.resolve(label: muse, text: text, start: start, end: end, gap: gap)
        let label: String?
        switch verdict.who {
        case .me: label = Self.me
        case .person(let id): label = "p:\(id)"
        case .someone: label = muse
        }
        if let label, let muse { museLabel[label] = muse }
        lastWhy = verdict.why
        var entry: [String: Any] = ["event": "speaker", "muse": muse ?? "-", "who": name(for: label),
                                    "sure": verdict.sure, "why": verdict.why, "words": text.split(separator: " ").count]
        if let match { entry["ownVoice"] = (Double(match) * 100).rounded() / 100 }
        if let gap { entry["gapDb"] = (Double(gap) * 10).rounded() / 10 }
        if !speakers.ownVoiceTrusted { entry["ownVoiceTrusted"] = false }
        SpeedLog.record(entry)

        // The aid's profile of "them" follows whoever is talking.
        if case .person(let id) = verdict.who {
            heard(id)
            lastPersonLine = end
            seed(id)
        }
        speaking = { if case .person(let id) = verdict.who { return id } else { return nil } }()
        meSpeaking = verdict.who == .me
        if meSpeaking { lastOwnVoiceFlip = end }
        refreshGroup()
        aid.heard(line: text, speaker: label, level: nil)
    }

    private func ownSpeech(_ text: String) {
        speakers.ownVoice(text)
        guard armed, !meSpeaking, speakers.wearerTalking() == true else { return }
        meSpeaking = true
        lastOwnVoiceFlip = Date()
        refreshGroup()
    }

    // MARK: - The group

    /// Who joined the conversation and when we last saw or heard them.
    private struct Joined {
        var since: Date
        var sightings = 0
        var seen = Date.distantPast
        var heard = Date.distantPast
        var member: Bool { sightings >= 3 || heard > .distantPast }
        var last: Date { max(seen, heard) }
    }
    @ObservationIgnored private var joined: [String: Joined] = [:]
    @ObservationIgnored private var speaking: String?

    /// Seen this long ago and not heard since, they've left the conversation.
    private static let leaveAfter: TimeInterval = 60

    private func seen(_ ids: [String]) {
        guard armed else { return }
        let now = Date()
        for id in Set(ids) where !isWearer(id) {
            var entry = joined[id] ?? Joined(since: now)
            entry.sightings += 1
            entry.seen = now
            joined[id] = entry
        }
    }

    private func heard(_ id: String) {
        guard !isWearer(id) else { return }
        let now = Date()
        var entry = joined[id] ?? Joined(since: now)
        entry.heard = now
        joined[id] = entry
    }

    #if DEBUG
    /// PREVIEW_GROUP: a fixed group, so the lens can be checked without three people in the room.
    @ObservationIgnored var pinnedGroup: (members: [Member], meSpeaking: Bool)?
    #endif

    private func refreshGroup() {
        #if DEBUG
        if let pinnedGroup {
            members = pinnedGroup.members
            meSpeaking = pinnedGroup.meSpeaking
            glasses?.setGroup(pinnedGroup.members, meSpeaking: pinnedGroup.meSpeaking)
            return
        }
        #endif
        let now = Date()
        joined = joined.filter { now.timeIntervalSince($0.value.last) < Self.leaveAfter }
        if meSpeaking, speakers.wearerTalking(at: now) == false, now.timeIntervalSince(lastOwnVoiceFlip) > 2 {
            meSpeaking = false
        }
        let next = joined.filter(\.value.member).sorted { $0.value.since < $1.value.since }.compactMap { id, _ -> Member? in
            guard let person = person(id) else { return nil }
            return Member(id: id, name: firstName(person.name), headline: person.headline,
                          speaking: !meSpeaking && speaking == id)
        }
        if next != members { members = next }
        glasses?.setGroup(next, meSpeaking: meSpeaking && next.count >= 2)
    }
    @ObservationIgnored private var lastOwnVoiceFlip = Date.distantPast

    // MARK: - Faces

    /// The face side's "who is THEM": the known face the wearer is looking at. Seeds the aid's
    /// profile of the other person before they introduce themselves, and tells `Speakers` where
    /// the wearer is looking. Looking away (nil) keeps the profile: people glance off mid-sentence.
    private func facingChanged(_ id: String?) {
        speakers.looking(at: id.flatMap { isWearer($0) ? nil : $0 })
        guard armed, let id, !isWearer(id) else { return }
        seen([id])
        // Once people are talking, the profile follows the voice, not the gaze.
        guard Date().timeIntervalSince(lastPersonLine) > 20 else { return }
        seed(id)
    }

    private func seed(_ id: String) {
        guard id != met, let person = person(id) else { return }
        met = id
        aid.met(name: person.name, label: person.headline, facts: person.details.map(\.text))
    }

    private func person(_ id: String) -> Person? { store?.people.first { $0.id == id } }
    private func isWearer(_ id: String) -> Bool { person(id)?.isMe == true }
    private func firstName(_ name: String) -> String { name.split(separator: " ").first.map(String.init) ?? name }

    private func roster() -> [String: String] {
        var map: [String: String] = [:]
        for person in store?.people ?? [] where person.isMe != true {
            let first = firstName(person.name).lowercased()
            // Two people with one first name: an introduction can't tell them apart, so neither.
            map[first] = map[first] == nil ? person.id : ""
        }
        return map.filter { !$0.value.isEmpty }
    }
}
