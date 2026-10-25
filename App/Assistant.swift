import Foundation
import UIKit
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
    /// Starts true: every launch and redeploy comes up with the mic off until the pill turns it on.
    var mutedByUser = true
    /// Everyone in the conversation, in the order they joined, the one talking marked.
    private(set) var members: [Member] = []
    /// Muse's own voice label for each transcript line (Person A, B, … follow these).
    @ObservationIgnored private(set) var voices: [Int: String] = [:]
    @ObservationIgnored private var lineLevels: [Float] = []
    /// The last line loud enough to be the wearer's.
    @ObservationIgnored private(set) var lastLoud = Date.distantPast
    /// Loudness of each Muse voice's lines (dB, loudest 30% of each line).
    @ObservationIgnored private var voiceLevels: [String: [Float]] = [:]

    /// The wearer's voice: the loudest on average, once two voices have two lines each and the
    /// loudest leads by `meVoiceGap` dB.
    var meVoice: String? {
        func median(_ v: [Float]) -> Float { v.sorted()[v.count / 2] }
        let ranked = voiceLevels.filter { $0.value.count >= 2 }.map { ($0.key, median($0.value)) }.sorted { $0.1 > $1.1 }
        guard ranked.count >= 2, ranked[0].1 - ranked[1].1 >= Tuning.float("meVoiceGap", 1.5) else { return nil }
        return ranked[0].0
    }
    /// The wearer has the floor (the glasses' own mic hears them).
    private(set) var meSpeaking = false
    /// Why the last line was given to whoever it was, for the phone ("glasses heard you (80%)").
    private(set) var lastWhy = ""

    @ObservationIgnored let listener = Listener()
    @ObservationIgnored weak var glasses: Glasses? {
        didSet {
            glasses?.onFacing = { [weak self] id in self?.facingChanged(id) }
            glasses?.onSeen = { [weak self] ids in self?.seen(ids) }
            glasses?.onStranger = { [weak self] face, photo in self?.meet(face: face, photo: photo) }
            glasses?.onReplayFinished = { [weak self] ids in
                for id in ids { self?.crm?.forgetPerson(id); self?.store?.forget(id) }
            }
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
            crm?.rosterIDs = store?.people.filter { $0.isMe != true }.map(\.id) ?? []
        }
    }
    private(set) var aid: Aid {
        didSet {
            wire(aid)
            crm?.wearer = aid.config.wearer
            crm?.models = Self.recapModels(aid.config)
            crm?.glanceModels = Self.glanceModels(aid.config)
        }
    }
    /// The personal CRM keeps every conversation the aid hears (App/CRM.swift).
    @ObservationIgnored weak var crm: CRM? {
        didSet {
            guard let crm else { return }
            crm.wearer = aid.config.wearer
            crm.models = Self.recapModels(aid.config)
            crm.glanceModels = Self.glanceModels(aid.config)
            crm.onGlance = { [weak self] id, glance in self?.learned(id, glance) }
            aid.jarvisTools = crm.jarvisTools(current: { [weak self] in self?.met ?? self?.glasses?.facing })
            // ME for the wearer, a first name for someone face ID knows, else THEM.
            crm.retag = { [weak self] label in
                guard let self else { return label ?? "?" }
                let name = self.name(for: label)
                return name == "YOU" ? "ME" : name == "THEM" ? "THEM" : name.capitalized
            }
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

    /// Glances run every few lines mid-conversation: the backup's fast key first, so they never
    /// eat the rate-limited coach key the aid's suggestions need.
    private static func glanceModels(_ config: Aid.Config) -> [Aid.Model] {
        var models: [Aid.Model] = []
        // First: a small fast model on OpenRouter. On the Oct 25 Toby transcript Gemini 2.5 Flash
        // Lite took 1 s and $0.08 per 1,000 glances, with the name and fact right; Qwen 3.8 27B
        // took 7.5 s and $3.73. `glanceModel` swaps it without a build.
        if let openrouter = [config.backup, config.answers, config.coach].compactMap(\.self).first(where: { $0.provider == .openrouter }) {
            models.append(Aid.Model(provider: .openrouter, key: openrouter.key,
                                    model: Tuning.string("glanceModel", "google/gemini-2.5-flash-lite")))
            // Flash Lite gets rate-limited on OpenRouter (14 of 16 burst calls were 429s on Oct 25):
            // Gemini 2.5 Flash next (its own quota, 0.4 s), then GPT-4.1 nano (1.1 s).
            models.append(Aid.Model(provider: .openrouter, key: openrouter.key, model: "google/gemini-2.5-flash"))
            models.append(Aid.Model(provider: .openrouter, key: openrouter.key, model: "openai/gpt-4.1-nano"))
        }
        for model in [config.backup, config.answers, config.coach].compactMap(\.self) where !models.contains(model) {
            models.append(model)
        }
        return models
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
        aid.onName = { [weak self] name in self?.introduced(name) }
        // Jarvis answers from everything the wearer has on record.
        aid.personal = { [weak self] in self?.crm?.digest() ?? "" }
        aid.currentPerson = { [weak self] in
            guard let self, let id = self.met ?? self.glasses?.facing, !self.isWearer(id) else { return "" }
            return self.crm?.digest(only: id) ?? ""
        }
        // "Jarvis, remember…", "remind me to…", "save her": written to the record, about whoever
        // was named or, by default, whoever the wearer is talking to.
        aid.jarvisTools = crm?.jarvisTools(current: { [weak self] in self?.met ?? self?.glasses?.facing }) ?? []
        aid.onJarvis = { [weak self] text in
            guard Tuning.bool("jarvisVoice", true) else { return }
            self?.voice.speak(text)
        }
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
    /// Jarvis's voice in the glasses (Cartesia). Knob `jarvisVoice` false keeps it on the lens only.
    @ObservationIgnored let voice = Voice()

    init() {
        // Until the roster is in, the bundle's WearerName (WEARER_NAME), else Toby.
        let wearer = (Bundle.main.object(forInfoDictionaryKey: "WearerName") as? String)
            .flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 } ?? "Toby"
        aid = Self.makeAid(wearer: wearer)
        speakers = Speakers(wearer: wearer)
        // The glasses' mic at launch (Oct 24, asked for): only it tells the wearer apart by volume.
        // Watch for DAT 1.0.1's old failure, where streaming it with the camera killed both; the
        // menu still switches to the iPhone mic.
        listener.mic = .glasses
        UserDefaults.standard.set(Listener.Mic.glasses.rawValue, forKey: "mic")
        listener.onLog = { SpeedLog.record($0) }
        Listener.speakToGlasses = voice.available
        voice.onLog = { SpeedLog.record($0) }
        // Deaf while it talks, and a moment after: its own voice must not become a request.
        voice.onSpeaking = { [weak self] seconds in
            self?.listener.mute(until: Date().addingTimeInterval((seconds ?? 0) + 0.4))
        }
        listener.onPartial = { [weak self] text in
            guard let self else { return }
            if self.turnStarted == nil { self.turnStarted = Date().addingTimeInterval(-0.5) }
            self.aid.heard(partial: text)
            self.crm?.heardPartial(text)
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
        config.explicitOnly = Tuning.bool("aidExplicitOnly", false)
        if !Tuning.bool("aidCoach", true) { config.coach = nil }
        // Eager by default (2026-10-25): answers before the "?", suggestions in every lull, and
        // definitions for the wearer's own lines too. Each one has its Tuning switch to turn it back off.
        config.suggestions = Tuning.bool("aidSuggest", true)
        config.answerMine = Tuning.bool("aidAnswerMine", true)
        config.defineMine = Tuning.bool("aidDefineMine", true)
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
        aid.reset(trigger: "listening started (mic on, or app back to the foreground)")
        aid.warm()
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
        // Names of people likely here, so speech recognition spells them right.
        if let crm { listener.keywords = ["Jarvis"] + crm.keywords(roster: store?.people.map(\.name) ?? []) }
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
                if let self { Transcripts.shared.tick(self, faces: (self.crm?.live?.faces ?? []) + self.members.map(\.id)) }
            }
        }
    }

    /// One conversation is over (ended by hand, or 30 s of quiet): its notes are filed and the aid
    /// starts clean, still listening, for the next.
    func endConversation(trigger: String) {
        crm?.tick(force: true)
        aid.reset(trigger: "end of conversation: \(trigger)")
        voiceLevels = [:]
        voices = [:]
    }

    func disarm() {
        armed = false
        tick?.cancel()
        tick = nil
        // Mic off ends the conversation: save it and recap it now, not two minutes from now.
        crm?.tick(force: true)
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

    /// Introduction mode: "Hi, I'm Priya" names the unnamed person you just met or are looking
    /// at. On unless switched off from the menu; remembered across launches.
    var namesFromIntroductions: Bool = (UserDefaults.standard.object(forKey: "NameFromIntros") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(namesFromIntroductions, forKey: "NameFromIntros") }
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
        var verdict = speakers.resolve(label: muse, text: text, start: start, end: end, gap: gap)
        // Loud enough is the wearer: their mouth is closest to whichever mic is listening. A line
        // `meLoudGap` dB over the typical line (median of the last 30) is "Me", whatever else said.
        let level = listener.meter.level(listener.mic == .glasses ? .glasses : .phone, from: start, to: end)
        if let level {
            lineLevels.append(level)
            if lineLevels.count > 30 { lineLevels.removeFirst() }
            if let muse { voiceLevels[muse, default: []].append(level) }
        }
        // Glasses mic: the wearer is far louder at the glasses than at the phone. Everyone else ran
        // 7-12 dB louder there on Oct 24; at `meGapDb` and over, it's the wearer. On the phone
        // mic there's no telling by volume, so no line is called the wearer's here.
        if let gap {
            let mine = gap >= Tuning.float("meGapDb", 14)
            if mine { verdict = Speakers.Verdict(who: .me, sure: true, why: String(format: "%.0f dB louder at the glasses", gap)) }
            else if verdict.who == .me { verdict = Speakers.Verdict(who: .someone, sure: true, why: String(format: "only %.0f dB louder at the glasses", gap)) }
        }
        // Loud enough to be the wearer talking: what lets a new conversation start.
        if let gap, gap >= Tuning.float("meGapDb", 14) { lastLoud = end }
        else if gap == nil, let level, level >= Tuning.float("startDb", -24) { lastLoud = end }
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
        if let level { entry["db"] = (Double(level) * 10).rounded() / 10 }
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
        // The raw voice, so the transcript keeps one letter per voice whoever it's matched to.
        if let id = aid.lines.last?.id, let muse { voices[id] = muse }
        crm?.heard(text, speaker: label, command: aid.isCommand(text))
    }

    private func ownSpeech(_ text: String) {
        guard !voice.speaking else { return }   // the glasses' mics hearing Jarvis
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
                          speaking: !meSpeaking && speaking == id, lines: LensCards.info(person), fullName: person.name)
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
        if id == nil || !isWearer(id!) { crm?.facing(id) }
        guard armed, let id, !isWearer(id) else { return }
        seen([id])
        // Once people are talking, the profile follows the voice, not the gaze.
        guard Date().timeIntervalSince(lastPersonLine) > 20 else { return }
        seed(id)
    }

    private func seed(_ id: String) {
        // Someone just met has nothing to brief the aid with, and naming them "New person" would
        // stop it taking the name they introduce themselves with.
        guard id != met, !newcomers.contains(id), let person = person(id) else { return }
        met = id
        // What the roster says, then what the CRM kept from last time (summary, promises).
        aid.met(name: person.name, label: person.headline,
                facts: person.details.map(\.text) + (crm?.record(id).briefing ?? []))
    }

    // MARK: - Meeting someone new

    /// Faces met this session, newest last: their cards fill in as they talk.
    @ObservationIgnored private var newcomers: [String] = []

    /// The glasses held a face nobody knows while listening: a contact now, card up next scan.
    private func meet(face: [Float], photo: UIImage?) -> String? {
        // No photo, no person: a contact is never made without one (Oct 25).
        guard let crm, let store, let photo else { return nil }
        let id = crm.meet()
        store.meet(Person(id: id, name: CRM.newName, role: "", source: "Met just now"), face: face, photo: photo)
        newcomers.append(id)
        aid.metStranger()
        glasses?.demo.met(id)
        // A name already heard in this conversation, before the face was in focus, is theirs.
        if crm.live != nil, let name = aid.them.name, !aid.them.recognised { introduced(name) }
        return id
    }

    /// "I'm Priya" from the other person: the newest face met this conversation that has no name
    /// yet, else the unnamed face the glasses are on (a contact met earlier and never named).
    private func introduced(_ name: String) {
        guard namesFromIntroductions, let crm else { return }
        let unnamed = { (id: String) in crm.renamable(id) && self.person(id)?.name != name }
        if let id = newcomers.last(where: { crm.newcomer == $0 }), unnamed(id) {
            rename(id, name)
        } else if let id = glasses?.facing, !isWearer(id), unnamed(id) {
            rename(id, name)
        }
    }

    private func rename(_ id: String, _ name: String) {
        guard var person = person(id) else { return }
        person.name = name
        // A teammate's name: their roster profile fills the card, as in the lens test.
        if store?.linkToRoster(&person, heard: name) == true {
            SpeedLog.record(["event": "metLinked", "person": id, "roster": person.name])
        }
        crm?.named(id, person.name)
        store?.updateMet(person)
        glasses?.refresh(person)
        SpeedLog.record(["event": "metNamed", "person": id])
        glasses?.demo.named(id)
    }

    /// A glance at the conversation so far: who they are and what they've said, onto the card.
    private func learned(_ id: String, _ glance: Glance) {
        guard let crm, var person = person(id), crm.renamable(id) || newcomers.contains(id) else { return }
        // The CRM settled the name (heard, maybe corrected); the card follows it.
        if crm.renamable(id) { person.name = crm.name(id) }
        // The LLM heard their name: the same path as an introduction (card, People, demo task).
        if crm.renamable(id), person.name != CRM.newName, self.person(id)?.name != person.name {
            rename(id, person.name)
        } else if crm.renamable(id), person.name != CRM.newName {
            glasses?.demo.named(id)
        }
        // Linked to a teammate on the roster: their profile stays, the notes don't replace it.
        if store?.linkedToRoster.contains(id) == true {
            SpeedLog.record(["event": "metLearned", "person": id, "linked": true])
            return
        }
        if let label = glance.label { person.role = label }
        let facts = crm.facts(about: id).map(\.text)
        person.tie = facts.first
        person.highlights = facts.count > 1 ? Array(facts.dropFirst().prefix(2)) : nil
        store?.updateMet(person)
        glasses?.refresh(person)
        SpeedLog.record(["event": "metLearned", "person": id, "facts": facts.count, "name": person.name,
                         "heardName": glance.name ?? ""])
    }

    /// Reset demo: every contact met goes (the roster stays), and the prompt starts over.
    func resetDemo() {
        guard let crm, let store else { return }
        crm.dropLive()
        for contact in crm.contacts { crm.forgetPerson(contact.id); store.forget(contact.id) }
        store.rosterHidden = true
        aid.reset(trigger: "demoReset")
        newcomers = []
        joined = [:]
        met = nil
        glasses?.demoClear()
        glasses?.demo.reset()
    }

    #if DEBUG
    /// Simulator driver for demo mode, through the same paths a real conversation takes:
    /// calhacks13://demo/meet?photo=avi, /name?n=Avi, /fact?t=…, /jarvis, /answer, /next, /reset.
    func demoDrive(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let arg = { (name: String) in items.first { $0.name == name }?.value ?? "" }
        switch url.lastPathComponent {
        case "on": glasses?.demo.on = true
        case "next": glasses?.demoNext()
        case "meet":
            // The face shows as "Detecting face" first, then becomes the contact.
            glasses?.demoDetecting(true)
            let photo = ["png", "jpg", "jpeg"].lazy.compactMap { Bundle.main.path(forResource: arg("photo"), ofType: $0) }
                .first.flatMap(UIImage.init(contentsOfFile:))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else { return }
                self.glasses?.demoDetecting(false)
                let face = (0..<512).map { _ in Float.random(in: -1...1) }
                guard let id = self.meet(face: face, photo: photo) else { return }
                if let photo { self.store?.setAvatar(id, photo) }
                if let person = self.person(id) { self.glasses?.demoShow(person) }
            }
        case "name":
            if let id = newcomers.last { rename(id, arg("n")) }
        case "fact":
            // Filed in the CRM as a glance would, then onto the card the way `learned` puts it.
            guard let id = newcomers.last, let crm, var person = person(id) else { return }
            crm.demoFact(id, arg("t"))
            let facts = crm.facts(about: id).map(\.text)
            person.tie = facts.first
            person.highlights = facts.count > 1 ? Array(facts.dropFirst().prefix(2)) : nil
            store?.updateMet(person)
            glasses?.refresh(person)
        case "jarvis":
            // What the aid hands the lens as Jarvis works, then answers.
            var panel = JarvisPanel(request: "Where can I get pizza nearby?", started: Date())
            panel.steps = [.init(label: "Searching: pizza near Cal Hacks", done: true)]
            glasses?.showAid(LensView(jarvis: panel))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                panel.answer = "Sliver Pizzeria on Shattuck, a 6 minute walk. Open till 11."
                panel.answeredAt = Date()
                self?.glasses?.showAid(LensView(jarvis: panel))
            }
        case "answer":
            glasses?.showAid(LensView(cards: [Card(kind: .answer, title: "About 1,000 hackers this year",
                                                   detail: "How many people are at Cal Hacks?", id: 7)]))
        case "reset": resetDemo()
        default: break
        }
    }
    #endif

    /// The roster and the contacts kept from conversations.
    private func person(_ id: String) -> Person? { store?.contacts.first { $0.id == id } }
    private func isWearer(_ id: String) -> Bool { person(id)?.isMe == true }
    private func firstName(_ name: String) -> String {
        name == CRM.newName ? name : name.split(separator: " ").first.map(String.init) ?? name
    }

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
