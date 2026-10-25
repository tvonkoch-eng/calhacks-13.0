import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The personal CRM: who you met, what you talked about, what you learned, what you owe them.
///
/// One way in: `save(_ encounter:)`, the record of one finished conversation (name, a four-word
/// label, up to three facts, follow-ups, a one-line summary, when, roughly where, and the face-ID
/// match if there was one). The conversation aid hands that over when a conversation ends; until
/// it does, `heard`/`tick` build the same record here (a conversation closes after `gap` seconds
/// of quiet or when the mic goes off, and `Recap` summarizes it).
///
/// Consent is the data model's rule, not a setting:
/// - A record keys to a face-ID match (the roster, who opted in, or someone the wearer saved) or
///   to a new `.pending` contact. Pending contacts are never recognizable, nothing is looked up on
///   them, and they are deleted after `pendingDays` unless the wearer saves them.
/// - No audio and no transcript is ever written: only the notes. The transcript of the last
///   conversation stays in memory for a retry if the summary failed, then is gone.
///
/// Pure Foundation, so `Tests/run.sh` drives it on the Mac with a fake clock and a canned recap.
/// One file in Documents: crm.json.
struct Said: Equatable {
    /// Diarization label from the ASR ("A", "B"), kept so tags can be fixed at close.
    var speaker: String?
    /// ME / THEM once the aid knows who's who; the raw label before that.
    var who: String
    var text: String
    var at: Date
}

/// Someone met in a conversation who isn't on the roster. Roster people (people.json) opted in
/// and live in `Store`; these live here.
struct Contact: Codable, Identifiable, Equatable {
    enum Consent: String, Codable {
        /// Made from a conversation. Not recognizable; deleted after `CRM.pendingDays`.
        case pending
        /// The wearer kept them. May be recognized once the wearer adds their photos.
        case saved
    }

    let id: String
    var name: String
    var consent: Consent
    var created: Date
}

/// The record of one finished conversation: what the aid hands over, and what's kept.
struct Encounter: Equatable {
    var name: String?
    /// Four words: "evals startup founder".
    var label: String?
    var facts: [String] = []
    var followups: [Recap.Followup] = []
    var summary: String?
    /// The one line worth seeing next time ("asked about hiring").
    var hook: String?
    var topics: [String] = []
    var at: Date
    var ended: Date?
    /// Rough, human: "near Union Square, SF".
    var place: String?
    /// The roster or saved-contact id face ID matched, if any.
    var match: String?
    /// Where they work, how to reach them: what they said out loud.
    var details = Recap.Details()
    /// Things known about them before that this conversation showed are no longer true.
    var outdated: [String] = []
}

/// A kept conversation: notes only.
struct Conversation: Codable, Identifiable, Equatable {
    enum Recap: String, Codable { case done, failed }

    let id: UUID
    /// Roster id or contact id.
    var person: String
    var started: Date
    var ended: Date?
    var place: String?
    var label: String?
    var summary: String?
    var hook: String?
    var topics: [String] = []
    var recap: Recap = .done

    var length: TimeInterval { (ended ?? started).timeIntervalSince(started) }
}

struct Fact: Codable, Identifiable, Equatable {
    let id: UUID
    var person: String
    var text: String
    var learned: Date
    var conversation: UUID?
}

struct Reminder: Codable, Identifiable, Equatable {
    /// todo: you said you would. waiting: they said they would. checkIn: nobody said anything,
    /// but it has been a while.
    enum Kind: String, Codable { case todo, waiting, checkIn }

    let id: UUID
    var kind: Kind
    var person: String
    var text: String
    var due: Date
    var done: Date?
    var conversation: UUID?

    var open: Bool { done == nil }
}

@MainActor @Observable final class CRM {
    /// Newest first.
    private(set) var conversations: [Conversation] = []
    private(set) var contacts: [Contact] = []
    private(set) var facts: [Fact] = []
    private(set) var reminders: [Reminder] = []
    /// The conversation still being heard, in memory only.
    private(set) var live: Live?
    /// Why the last recap didn't happen, for the phone.
    private(set) var note = ""

    struct Live: Equatable {
        var started: Date
        /// Known faces looked at while it ran, in order of first look.
        var faces: [String] = []
        var lines: [Said] = []
    }

    /// A roster person, as the CRM needs them.
    struct Known {
        var name: String
        var about: String
    }

    // Wired by Assistant.
    /// Roster people by id; nil for anyone not on it.
    @ObservationIgnored var roster: (String) -> Known? = { _ in nil }
    /// Every roster id except the wearer, in roster order.
    @ObservationIgnored var rosterIDs: [String] = []
    /// The saved contacts changed: they join (or leave) the face matcher.
    @ObservationIgnored var onSaved: (([Contact]) -> Void)? { didSet { onSaved?(saved) } }
    /// The aid's current ME/THEM for a diarization label.
    @ObservationIgnored var retag: (String?) -> String = { $0 ?? "?" }
    /// The name and facts the live coach picked up, as a fallback when the recap fails.
    @ObservationIgnored var heardAboutThem: () -> (name: String?, facts: [String]) = { (nil, []) }
    /// Rough place for a new record ("near Union Square, SF"); nil when unknown.
    @ObservationIgnored var whereabouts: () async -> String? = { nil }
    /// Tried in order; the first that answers wins.
    @ObservationIgnored var models: [Aid.Model] = []
    @ObservationIgnored var wearer = "the wearer"
    /// A conversation turned up how to reach someone or where they work: onto their contact card,
    /// filling blanks only (what the wearer typed always wins).
    @ObservationIgnored var onDetails: ((String, Recap.Details) -> Void)?
    /// A reminder was added or moved (schedule a notification), or finished (cancel it).
    @ObservationIgnored var onScheduled: ((Reminder) -> Void)?
    @ObservationIgnored var onCancelled: ((UUID) -> Void)?
    /// Replaces the model call in tests.
    @ObservationIgnored var recapper: ((Recap.Input) async throws -> Recap.Result)?
    /// Models for the glances while someone new is talking: fast ones first, the coach's key is
    /// rate limited and the aid needs it more.
    @ObservationIgnored var glanceModels: [Aid.Model] = []
    /// Replaces the glance model call in tests.
    @ObservationIgnored var glancer: ((Recap.Input) async throws -> Glance)?
    /// A glance learned something about someone met in this conversation: show it now.
    @ObservationIgnored var onGlance: ((String, Glance) -> Void)?
    /// A contact was deleted (forgotten, expired, merged): drop their face and photo too.
    @ObservationIgnored var onForgot: ((String) -> Void)? {
        didSet { forgottenEarly.forEach { onForgot?($0) }; forgottenEarly = [] }
    }
    /// Expired at launch, before anyone was listening for it.
    @ObservationIgnored private var forgottenEarly: [String] = []

    /// Quiet this long ends a conversation.
    var gap: TimeInterval { Self.knob("crmGap", 120) }
    /// Shorter than this many lines is a hello in passing, not a conversation.
    var minLines: Int { Int(Self.knob("crmMinLines", 3)) }
    /// How long after you last talked a "catch up" reminder comes due.
    var checkInDays: Int { Int(Self.knob("checkInDays", 14)) }
    /// How long someone you met but didn't save is kept.
    var pendingDays: Double { Self.knob("pendingDays", 7) }

    private static func knob(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.double(forKey: key)
    }

    private let url: URL?
    @ObservationIgnored private var lastLine = Date.distantPast
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var facing: String?
    @ObservationIgnored private var lastSaved: [Contact] = []
    /// The last failed conversation's transcript, for "Summarize again". Memory only.
    @ObservationIgnored private var retry: (id: UUID, input: Recap.Input)?
    /// Someone met by face in the conversation being heard (`meet`), whose card fills in as they talk.
    @ObservationIgnored private(set) var newcomer: String?
    /// Whether the newcomer has said anything in the conversation they were met in.
    @ObservationIgnored private var newcomerSpoke = false
    @ObservationIgnored private var glancing = false
    @ObservationIgnored private var lastGlance = Date.distantPast
    @ObservationIgnored private var glancedLines = 0
    /// At most one glance this often, and only after this many new lines from them.
    var glanceEvery: TimeInterval { Self.knob("glanceEvery", 12) }
    var glanceLines: Int { Int(Self.knob("glanceLines", 2)) }

    /// What a new contact is called until they say their name.
    static let newName = "New person"

    init(url: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("crm.json"), now: Date = .now) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let saved = try? Self.decoder.decode(Saved.self, from: data) {
            conversations = saved.conversations
            contacts = saved.contacts
            facts = saved.facts
            reminders = saved.reminders
        }
        expire(now: now)
    }

    // MARK: - The one way in

    /// Keeps one finished conversation. Returns who it was filed under (a roster id, a saved
    /// contact, or a new pending contact), or nil when there was nobody to file it under.
    @discardableResult func save(_ encounter: Encounter, recap: Conversation.Recap = .done) -> String? {
        guard let person = key(for: encounter) else { return nil }
        file(encounter, under: person, recap: recap)
        return person
    }

    private func file(_ encounter: Encounter, under person: String, recap: Conversation.Recap) {
        if let name = encounter.name, let i = contacts.firstIndex(where: { $0.id == person && $0.name == Self.newName }) {
            contacts[i].name = name
        }
        let conversation = Conversation(id: UUID(), person: person, started: encounter.at, ended: encounter.ended,
                                        place: encounter.place, label: encounter.label, summary: encounter.summary,
                                        hook: encounter.hook, topics: Array(encounter.topics.prefix(3)), recap: recap)
        conversations.insert(conversation, at: 0)
        let when = encounter.ended ?? encounter.at
        // "Moved to Stripe" retires "works at Ramp": the record says what's true now.
        facts.removeAll { fact in fact.person == person && encounter.outdated.contains { Talk.same($0, fact.text) } }
        for text in encounter.facts.prefix(3) where !text.isEmpty {
            guard !facts.contains(where: { $0.person == person && Talk.same($0.text, text) }) else { continue }
            facts.append(Fact(id: UUID(), person: person, text: text, learned: when, conversation: conversation.id))
        }
        for followup in encounter.followups.prefix(3) where !followup.text.isEmpty {
            let days = followup.dueInDays ?? (followup.mine ? 1 : 3)
            let reminder = Reminder(id: UUID(), kind: followup.mine ? .todo : .waiting, person: person,
                                    text: followup.text, due: Self.due(days, from: when), conversation: conversation.id)
            reminders.append(reminder)
            onScheduled?(reminder)
        }
        scheduleCheckIn(person, after: when, conversation: conversation.id)
        if !encounter.details.isEmpty { onDetails?(person, encounter.details) }
        save()
    }

    /// The face-ID match when there is one and it may be recognized; else the pending contact
    /// with the same name met in the last day (people say their name twice); else a new one.
    private func key(for encounter: Encounter) -> String? {
        // A pending match is someone met by face in this very conversation (`meet`): pending
        // contacts are never recognized otherwise.
        if let match = encounter.match, roster(match) != nil || contacts.contains(where: { $0.id == match }) {
            return match
        }
        guard let name = encounter.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            // Nobody to file it under. Better a nameless pending contact than losing a promise.
            guard !encounter.followups.isEmpty || encounter.summary != nil else { return nil }
            return newContact("Someone new", at: encounter.at)
        }
        let recent = encounter.at.addingTimeInterval(-86400)
        if let same = contacts.first(where: { Talk.same($0.name, name) && $0.created > recent }) { return same.id }
        return newContact(name, at: encounter.at)
    }

    private func newContact(_ name: String, at date: Date) -> String {
        let contact = Contact(id: "met-\(UUID().uuidString.prefix(8).lowercased())", name: name, consent: .pending, created: date)
        contacts.append(contact)
        return contact.id
    }

    // MARK: - Hearing a conversation (until the aid hands over its own record)

    /// One finished line from the aid. Commands to the glasses ("Lens, …") aren't conversation.
    func heard(_ text: String, speaker: String?, at now: Date = .now, command: Bool = false) {
        guard !command, !text.isEmpty else { return }
        // Someone met by face before anyone spoke belongs to it even if the wearer looked away.
        if live == nil { live = Live(started: now, faces: [newcomer, facing].compactMap { $0 }.uniqued) }
        if let newcomer, speaker == "p:\(newcomer)" { newcomerSpoke = true }
        live?.lines.append(Said(speaker: speaker, who: retag(speaker), text: text, at: now))
        lastLine = now
        watchForQuiet()
        glanceIfDue(now: now)
    }

    /// While someone new is in the conversation, a quick look at it so far every few lines: their
    /// name, who they are, what they've said about themselves. Facts are kept as they come, so the
    /// phone and the lens fill in during the conversation, not after it.
    private func glanceIfDue(now: Date) {
        guard let id = newcomer, let conversation = live, conversation.faces.contains(id), !glancing,
              now.timeIntervalSince(lastGlance) >= glanceEvery else { return }
        let theirs = conversation.lines.filter { $0.who != "ME" }.count
        guard theirs - glancedLines >= glanceLines else { return }
        glancing = true
        lastGlance = now
        glancedLines = theirs
        let input = Recap.Input(wearer: wearer, when: conversation.started,
                                with: nil, name: contacts.first { $0.id == id && $0.name != Self.newName }?.name,
                                known: facts(about: id).map(\.text), owed: [],
                                transcript: conversation.lines.map { "\(label(retag($0.speaker))): \($0.text)" })
        Task {
            defer { glancing = false }
            guard let glance = await look(input), contacts.contains(where: { $0.id == id }) else { return }
            if let name = glance.name, contacts.first(where: { $0.id == id })?.name == Self.newName { named(id, name) }
            for text in glance.facts where !facts.contains(where: { $0.person == id && Talk.same($0.text, text) }) {
                facts.append(Fact(id: UUID(), person: id, text: text, learned: .now))
            }
            if let label = glance.label { liveLabels[id] = label }
            save()
            onGlance?(id, glance)
        }
    }

    private func look(_ input: Recap.Input) async -> Glance? {
        if let glancer { return try? await glancer(input) }
        for model in glanceModels {
            if let glance = try? await Glance.ask(input, model: model) { return glance }
        }
        return nil
    }

    /// The label a glance gave someone met in the conversation still going, until a recap files one.
    @ObservationIgnored private var liveLabels: [String: String] = [:]

    /// A face nobody knows, held in view while the aid listens: a new pending contact now, so the
    /// lens can put a card up before they've said a word. It fills in as they talk (`onGlance`)
    /// and the conversation files under them when it ends. Pending like anyone met: no catch-up,
    /// gone after `pendingDays` unless kept.
    @discardableResult func meet(at now: Date = .now) -> String {
        let id = newContact(Self.newName, at: now)
        newcomer = id
        newcomerSpoke = false
        glancedLines = 0
        if live?.faces.contains(id) == false { live?.faces.append(id) }
        save()
        return id
    }

    /// Someone met just now said their name.
    func named(_ person: String, _ name: String) {
        guard let i = contacts.firstIndex(where: { $0.id == person }), contacts[i].name != name else { return }
        contacts[i].name = name
        save()
    }

    /// The known face the wearer is looking at. Joins the live conversation; a look between
    /// conversations is remembered so the next one starts with them.
    func facing(_ id: String?) {
        facing = id
        guard let id, live != nil, live?.faces.contains(id) == false else { return }
        live?.faces.append(id)
    }

    /// Called on a timer and when the mic goes off. Closes the live conversation once it's been
    /// quiet for `gap`, or now when `force`.
    func tick(now: Date = .now, force: Bool = false) {
        guard var conversation = live, force || now.timeIntervalSince(lastLine) >= gap else { return }
        live = nil
        // Someone met by face who never spoke in this conversation was in the background, not in
        // it: nothing is filed under them, and the pending contact goes.
        if let id = newcomer, !newcomerSpoke {
            conversation.faces.removeAll { $0 == id }
            forgetPerson(id)
        }
        newcomer = nil
        newcomerSpoke = false
        watch?.cancel()
        // Who's who is often only settled late (an introduction, the wearer's louder voice).
        for i in conversation.lines.indices where conversation.lines[i].speaker != nil {
            conversation.lines[i].who = retag(conversation.lines[i].speaker)
        }
        guard conversation.lines.count >= minLines else { return }
        let them = heardAboutThem()
        Task { await close(conversation, heard: them) }
    }

    private func watchForQuiet() {
        watch?.cancel()
        let wait = gap
        watch = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait + 1))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    private func close(_ conversation: Live, heard them: (name: String?, facts: [String])) async {
        let match = conversation.faces.first
        let place = await whereabouts()
        let input = Recap.Input(
            wearer: wearer, when: conversation.started,
            with: match.flatMap { roster($0) ?? contacts.first { $0.id == match }.map { Known(name: $0.name, about: "") } }
                .map { $0.about.isEmpty ? $0.name : "\($0.name) (\($0.about))" },
            name: them.name,
            known: match.map { id in facts.filter { $0.person == id }.map(\.text) } ?? [],
            owed: match.map { id in open(for: id).filter { $0.kind != .checkIn }.map(\.text) } ?? [],
            transcript: conversation.lines.map { "\(label($0.who)): \($0.text)" })
        var encounter = Encounter(name: them.name, at: conversation.started, ended: conversation.lines.last?.at,
                                  place: place, match: match)
        if let result = await summarize(input) {
            if result.skip { return }
            encounter.apply(result)
            save(encounter)
        } else {
            // Keep what the live coach learned; the summary can be retried while the app runs.
            encounter.facts = them.facts
            if let person = save(encounter, recap: .failed), let id = conversations.first(where: { $0.person == person })?.id {
                retry = (id, input)
            }
        }
    }

    private func summarize(_ input: Recap.Input) async -> Recap.Result? {
        var failure = ""
        if let recapper {
            do { note = ""; return try await recapper(input) } catch { failure = "\(error)" }
        } else {
            if models.isEmpty { failure = "No model key for recaps." }
            for model in models {
                do { let result = try await Recap.ask(input, model: model); note = ""; return result }
                catch { failure = "\(model.provider): \(error)" }
            }
        }
        note = failure
        return nil
    }

    func canRetry(_ id: UUID) -> Bool { retry?.id == id }

    /// "Summarize again" on a failed conversation, while its transcript is still in memory.
    func retryRecap(_ id: UUID) async {
        guard let retry, retry.id == id, let result = await summarize(retry.input),
              let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        self.retry = nil
        let old = conversations.remove(at: i)
        facts.removeAll { $0.conversation == id }
        var encounter = Encounter(at: old.started, ended: old.ended, place: old.place)
        encounter.apply(result)
        if result.skip { save(); return }
        file(encounter, under: old.person, recap: .done)
    }

    private func label(_ who: String) -> String {
        who == "ME" ? "ME (\(wearer))" : who == "THEM" || who == "?" ? who : "SPEAKER \(who)"
    }

    /// "In 0 days" means later today; anything else lands at 9 in the morning.
    static func due(_ days: Int, from base: Date, calendar: Calendar = .current) -> Date {
        if days <= 0 { return base.addingTimeInterval(2 * 3600) }
        let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: base)) ?? base
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }

    /// Talking to someone resets their catch-up clock: one open check-in per person, moved out.
    /// Not for pending contacts: nobody to catch up with until the wearer decides to keep them.
    private func scheduleCheckIn(_ person: String, after date: Date, conversation: UUID) {
        guard consent(person) != .pending else { return }
        for reminder in reminders where reminder.kind == .checkIn && reminder.person == person && reminder.open {
            onCancelled?(reminder.id)
        }
        reminders.removeAll { $0.kind == .checkIn && $0.person == person }
        let reminder = Reminder(id: UUID(), kind: .checkIn, person: person, text: "Catch up with \(first(person))",
                                due: Self.due(checkInDays, from: date), conversation: conversation)
        reminders.append(reminder)
        onScheduled?(reminder)
    }

    // MARK: - Consent

    /// nil for roster people (they opted in), else the contact's consent.
    func consent(_ person: String) -> Contact.Consent? {
        roster(person) != nil ? nil : contacts.first { $0.id == person }?.consent
    }

    /// The wearer keeps someone they met: they get a catch-up clock and may be recognized once
    /// the wearer adds photos of them.
    func keep(_ person: String, name: String? = nil) {
        guard let i = contacts.firstIndex(where: { $0.id == person }) else { return }
        contacts[i].consent = .saved
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { contacts[i].name = name }
        if let last = conversations.first(where: { $0.person == person }) {
            scheduleCheckIn(person, after: last.ended ?? last.started, conversation: last.id)
        }
        save()
    }

    /// Someone the wearer adds by hand ("+" on People): kept from the start, since they chose to.
    @discardableResult func add(name: String, at now: Date = .now) -> String {
        let id = "c-" + UUID().uuidString.prefix(8).lowercased()
        contacts.append(Contact(id: id, name: name, consent: .saved, created: now))
        save()
        return id
    }

    /// The wearer renamed a contact (roster names are edited in `Store`).
    func rename(_ person: String, to name: String) {
        guard let i = contacts.firstIndex(where: { $0.id == person }),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        contacts[i].name = name
        save()
    }

    /// Something the wearer knows about them, typed in rather than heard.
    func learn(_ person: String, _ text: String, at now: Date = .now) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        facts.insert(Fact(id: UUID(), person: person, text: text, learned: now), at: 0)
        save()
    }

    /// Forget everything about someone who isn't on the roster.
    func forgetPerson(_ person: String) {
        guard roster(person) == nil else { return }
        if let onForgot { onForgot(person) } else { forgottenEarly.append(person) }
        let ids = Set(reminders.filter { $0.person == person }.map(\.id))
        ids.forEach { onCancelled?($0) }
        contacts.removeAll { $0.id == person }
        conversations.removeAll { $0.person == person }
        facts.removeAll { $0.person == person }
        reminders.removeAll { $0.person == person }
        save()
    }

    /// Pending contacts older than `pendingDays` go, with everything about them.
    func expire(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-pendingDays * 86400)
        for contact in contacts where contact.consent == .pending && contact.created < cutoff { forgetPerson(contact.id) }
    }

    /// Face ID missed someone already known: move a contact's notes onto them.
    func merge(_ contact: String, into person: String) {
        guard contact != person else { return }
        for i in conversations.indices where conversations[i].person == contact { conversations[i].person = person }
        for i in facts.indices where facts[i].person == contact { facts[i].person = person }
        for i in reminders.indices where reminders[i].person == contact { reminders[i].person = person }
        reminders.removeAll { $0.person == person && $0.kind == .checkIn }
        contacts.removeAll { $0.id == contact }
        onForgot?(contact)
        if let last = conversations.first(where: { $0.person == person }) {
            scheduleCheckIn(person, after: last.ended ?? last.started, conversation: last.id)
        }
        save()
    }

    // MARK: - What the wearer does with it

    func complete(_ id: UUID) {
        guard let i = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[i].done = reminders[i].open ? .now : nil
        if reminders[i].open { onScheduled?(reminders[i]) } else { onCancelled?(id) }
        save()
    }

    func snooze(_ id: UUID, days: Int = 1) {
        guard let i = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[i].due = Self.due(days, from: max(.now, reminders[i].due))
        onScheduled?(reminders[i])
        save()
    }

    func remind(_ person: String, _ text: String, due: Date) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let reminder = Reminder(id: UUID(), kind: .todo, person: person, text: text, due: due)
        reminders.append(reminder)
        onScheduled?(reminder)
        save()
    }

    func deleteReminder(_ id: UUID) {
        reminders.removeAll { $0.id == id }
        onCancelled?(id)
        save()
    }

    func forget(_ fact: UUID) {
        facts.removeAll { $0.id == fact }
        save()
    }

    func delete(_ conversation: UUID) {
        conversations.removeAll { $0.id == conversation }
        facts.removeAll { $0.conversation == conversation }
        for reminder in reminders where reminder.conversation == conversation && reminder.kind != .checkIn {
            onCancelled?(reminder.id)
        }
        reminders.removeAll { $0.conversation == conversation && $0.kind != .checkIn }
        save()
    }

    // MARK: - Reading it back

    func name(_ person: String) -> String { roster(person)?.name ?? contacts.first { $0.id == person }?.name ?? "Someone" }
    func first(_ person: String) -> String { name(person).split(separator: " ").first.map(String.init) ?? name(person) }

    func conversations(with person: String) -> [Conversation] { conversations.filter { $0.person == person } }
    func facts(about person: String) -> [Fact] { facts.filter { $0.person == person }.sorted { $0.learned > $1.learned } }
    func open(for person: String) -> [Reminder] {
        reminders.filter { $0.open && $0.person == person }.sorted { $0.due < $1.due }
    }

    /// Open reminders due by the end of `horizon` days, soonest first: the home screen's list.
    func upcoming(now: Date = .now, horizon: Int = 1, calendar: Calendar = .current) -> [Reminder] {
        let end = calendar.date(byAdding: .day, value: horizon + 1, to: calendar.startOfDay(for: now)) ?? now
        return reminders.filter { $0.open && $0.due < end }.sorted { $0.due < $1.due }
    }

    /// People met but not yet kept, newest first.
    var pending: [Contact] { contacts.filter { $0.consent == .pending }.sorted { $0.created > $1.created } }
    /// People the wearer kept. Recognizable once they have photos.
    var saved: [Contact] { contacts.filter { $0.consent == .saved } }

    /// The most recent four-word label for them ("evals startup founder").
    func label(_ person: String) -> String? { conversations(with: person).lazy.compactMap(\.label).first ?? liveLabels[person] }

    /// The single most useful line from last time: what you owe them, else what they owe you,
    /// else the hook, else the first topic.
    func lastLine(_ person: String) -> String? {
        let open = open(for: person)
        if let todo = open.first(where: { $0.kind == .todo }) { return "you said: \(todo.text.lowercasedFirst)" }
        if let waiting = open.first(where: { $0.kind == .waiting }) { return "waiting on: \(waiting.text.lowercasedFirst)" }
        guard let last = conversations(with: person).first(where: { $0.recap == .done }) else { return nil }
        return last.hook ?? last.topics.first ?? last.summary
    }

    /// "Priya · evals startup founder · asked about hiring": the lens line when face ID matches.
    func lastContext(_ person: String) -> String? {
        let parts = [label(person), lastLine(person)].compactMap { $0 }
        return parts.isEmpty ? nil : ([first(person)] + parts).joined(separator: " \u{00B7} ")
    }

    /// Everything known about someone, for the aid to start the next conversation already knowing
    /// them.
    struct Record {
        var name: String
        var label: String?
        var facts: [String]
        var lastSummary: String?
        var lastMet: Date?
        var youOwe: [String]
        var theyOwe: [String]

        /// As lines for `Aid.met(facts:)`.
        var briefing: [String] {
            var lines = facts
            if let lastSummary, let lastMet {
                lines.append("Last talked \(lastMet.formatted(.dateTime.month(.abbreviated).day())): \(lastSummary)")
            }
            lines += youOwe.map { "Wearer promised: \($0)" } + theyOwe.map { "They promised: \($0)" }
            return lines
        }
    }

    func record(_ person: String) -> Record {
        let last = conversations(with: person).first { $0.summary != nil }
        let open = open(for: person)
        return Record(name: name(person), label: label(person), facts: facts(about: person).prefix(6).map(\.text),
                      lastSummary: last?.summary, lastMet: last?.started,
                      youOwe: open.filter { $0.kind == .todo }.map(\.text),
                      theyOwe: open.filter { $0.kind == .waiting }.map(\.text))
    }

    /// Everything on record, one line a person, for Jarvis: "who did I meet today", "what did I
    /// promise Avi", "who here works at Google". People talked to come first, newest first, then
    /// anyone owed something, then the rest of the roster and the people kept. At most `limit` people,
    /// so it stays a small prompt; it never leaves the answer model (research gets the task only).
    func digest(now: Date = .now, limit: Int = 30) -> String {
        let when = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
        var order: [String] = []
        func add(_ id: String) { if !order.contains(id) { order.append(id) } }
        conversations.sorted { $0.started > $1.started }.forEach { add($0.person) }
        reminders.filter(\.open).forEach { add($0.person) }
        facts.forEach { add($0.person) }
        rosterIDs.forEach(add)
        saved.forEach { add($0.id) }

        var lines: [String] = []
        for id in order.prefix(limit) {
            var parts: [String] = []
            let pending = contacts.first { $0.id == id }?.consent == .pending
            var who = name(id)
            if let about = roster(id)?.about, !about.isEmpty { who += " (\(about))" }
            else if let label = label(id) { who += " (\(label))" }
            if pending { who += ", met, not saved yet" }
            parts.append(who)
            let talks = conversations(with: id).sorted { $0.started > $1.started }
            if let last = talks.first {
                var met = "last talked \(last.started.formatted(when))"
                if let place = last.place { met += " \(place)" }
                if talks.count > 1 { met += " (\(talks.count) conversations)" }
                if let summary = last.summary { met += ": \(summary)" }
                if !last.topics.isEmpty { met += " Topics: \(last.topics.joined(separator: ", "))." }
                parts.append(met)
            } else if roster(id) != nil {
                parts.append("haven't talked yet")
            }
            let known = facts(about: id).prefix(5).map(\.text)
            if !known.isEmpty { parts.append("Facts: " + known.joined(separator: "; ")) }
            for reminder in open(for: id) {
                let due = reminder.due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
                switch reminder.kind {
                case .todo: parts.append("You promised: \(reminder.text) (due \(due))")
                case .waiting: parts.append("They promised: \(reminder.text)")
                case .checkIn: parts.append("Check in by \(due)")
                }
            }
            lines.append("- " + parts.joined(separator: ". "))
        }
        return lines.isEmpty ? "" : "People:\n" + lines.joined(separator: "\n")
    }

    /// Who "Priya", "Avi Shah" or "her" means: a full name, then a first name (whoever was talked
    /// to most recently, if two share it). A pronoun or nothing is whoever the wearer is talking to
    /// now (`current`). Nil when nobody on record goes by that name.
    func find(_ said: String?, current: String?) -> String? {
        let name = (said ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let deictic = ["", "her", "him", "them", "they", "she", "he", "this person", "this guy", "the person",
                       "the person i'm talking to", "who i'm talking to"]
        if deictic.contains(name) { return current }
        let recent = conversations.sorted { $0.started > $1.started }.map(\.person)
        var ids: [String] = []
        for id in recent + rosterIDs + contacts.map(\.id) where !ids.contains(id) { ids.append(id) }
        if let exact = ids.first(where: { self.name($0).lowercased() == name }) { return exact }
        let first = name.split(separator: " ").first.map(String.init) ?? name
        return ids.first { self.first($0).lowercased() == first }
    }

    /// What Jarvis may write: remember a fact, set a follow-up, save someone met. `current` is
    /// whoever the wearer is talking to now. Each says back what it did, for the lens and the voice.
    func jarvisTools(current: @escaping @MainActor () -> String?) -> [ExtraTool] {
        let person = #""person": {"type": "string", "description": "Who, as the wearer named them; empty for whoever they're talking to now"}"#
        return [
            ExtraTool(name: "remember", definition: """
                {"type": "function", "function": {"name": "remember",
                 "description": "Save a fact about someone to the wearer's record (\\"remember Priya is hiring\\").",
                 "parameters": {"type": "object", "properties": {\(person),
                   "fact": {"type": "string", "description": "The fact, short, in the third person: 'Hiring a founding engineer'"}},
                  "required": ["fact"]}}}
                """, working: "Saving it") { @MainActor [weak self] json in
                let a = Tools.arguments(json)
                do {
                    guard let self else { throw CancellationError() }
                    let fact = (a["fact"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                    guard !fact.isEmpty else { return ToolResult(title: "Nothing to save", detail: "", icon: "exclamationCircle") }
                    let said = a["person"] as? String
                    guard let id = self.find(said, current: current()) ?? said.flatMap({ $0.isEmpty ? nil : self.add(name: $0) }) else {
                        return ToolResult(title: "Who is that about?", detail: "", icon: "exclamationCircle")
                    }
                    self.learn(id, fact)
                    return ToolResult(title: "Saved for \(self.first(id))", detail: fact, icon: "starCircleTriangleAi")
                }
            },
            ExtraTool(name: "follow_up", definition: """
                {"type": "function", "function": {"name": "follow_up",
                 "description": "Something the wearer will do for or with someone, tracked on their record with a reminder (\\"remind me to send Avi the deck tomorrow\\").",
                 "parameters": {"type": "object", "properties": {\(person),
                   "task": {"type": "string", "description": "What the wearer will do, as an instruction: 'Send Avi the deck'"},
                   "days": {"type": "integer", "description": "Due in this many days: 0 today, 1 tomorrow (the default)"}},
                  "required": ["task"]}}}
                """, working: "Setting a follow-up") { @MainActor [weak self] json in
                let a = Tools.arguments(json)
                do {
                    guard let self else { throw CancellationError() }
                    let task = (a["task"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                    guard !task.isEmpty, let id = self.find(a["person"] as? String, current: current()) else {
                        return ToolResult(title: "Who is that for?", detail: "", icon: "exclamationCircle")
                    }
                    let days = (a["days"] as? Int) ?? Int(a["days"] as? String ?? "") ?? 1
                    let due = CRM.due(max(0, days), from: Date())
                    self.remind(id, task, due: due)
                    let when = days <= 0 ? "today" : days == 1 ? "tomorrow" : due.formatted(.dateTime.weekday(.wide))
                    return ToolResult(title: "\(task), \(when)", detail: "", icon: "bell")
                }
            },
            ExtraTool(name: "save_contact", definition: """
                {"type": "function", "function": {"name": "save_contact",
                 "description": "Keep someone the wearer just met in their contacts, so they're remembered next time.",
                 "parameters": {"type": "object", "properties": {\(person),
                   "name": {"type": "string", "description": "Their name, if the wearer said it"}}}}}
                """, working: "Saving the contact") { @MainActor [weak self] json in
                let a = Tools.arguments(json)
                do {
                    guard let self else { throw CancellationError() }
                    let name = (a["name"] as? String)?.trimmingCharacters(in: .whitespaces)
                    if let id = self.find(a["person"] as? String ?? name, current: current()) {
                        if self.consent(id) == .pending { self.keep(id, name: name) }
                        return ToolResult(title: "\(self.name(id)) saved", detail: "", icon: "starCircleTriangleAi")
                    }
                    guard let name, !name.isEmpty else { return ToolResult(title: "Who should I save?", detail: "", icon: "exclamationCircle") }
                    let id = self.add(name: name)
                    return ToolResult(title: "\(self.name(id)) saved", detail: "", icon: "starCircleTriangleAi")
                }
            },
        ]
    }

    /// Names likely to come up at the event right now, for speech recognition keywords so they're
    /// spelled right: the roster, people kept, and anyone met in the last day. First and last
    /// names separately, most recent first, no repeats.
    func keywords(roster names: [String], now: Date = .now) -> [String] {
        let recent = now.addingTimeInterval(-86400)
        let met = conversations.filter { $0.started > recent }.map { name($0.person) }
        var seen = Set<String>(), words: [String] = []
        for name in met + saved.map(\.name) + names {
            for word in name.split(separator: " ").map(String.init) where word.count > 1 && word != "Someone" && word != "new" {
                if seen.insert(word.lowercased()).inserted { words.append(word) }
            }
        }
        return words
    }

    // MARK: - Disk

    private struct Saved: Codable {
        var conversations: [Conversation]
        var contacts: [Contact]
        var facts: [Fact]
        var reminders: [Reminder]
    }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()

    private func save() {
        if saved != lastSaved { lastSaved = saved; onSaved?(saved) }
        guard let url else { return }
        let saved = Saved(conversations: conversations, contacts: contacts, facts: facts, reminders: reminders)
        try? Self.encoder.encode(saved).write(to: url, options: [.atomic, .completeFileProtection])
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

private extension Array where Element == String {
    var uniqued: [String] { reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
}

extension Encounter {
    /// Fills the record from a recap; the face match, time and place stay.
    mutating func apply(_ result: Recap.Result) {
        name = name ?? result.name
        label = result.label
        summary = result.summary
        hook = result.hook
        topics = result.topics
        facts = result.facts
        followups = result.followups
        details = result.details
        outdated = result.outdated
    }
}

/// One call per finished conversation: the `Encounter` fields from a transcript.
enum Recap {
    struct Input {
        var wearer: String
        var when: Date
        /// "Avi Shah (LSE Economics, year abroad at UCSB)" when face ID knew them.
        var with: String?
        /// A name they introduced themselves with.
        var name: String?
        var known: [String]
        var owed: [String]
        var transcript: [String]
    }

    struct Followup: Equatable {
        var text: String
        /// The wearer owes it (todo) or the other person does (waiting).
        var mine: Bool = true
        var dueInDays: Int?
    }

    /// What someone said about where they are and how to reach them. Cleaned on the way in
    /// (`Details.clean`), so a misheard "my email is" never lands as a broken address.
    struct Details: Codable, Equatable {
        var work: String?
        var school: String?
        var from: String?
        var phone: String?
        var email: String?
        /// The profile slug: "priya-shah" for linkedin.com/in/priya-shah.
        var linkedin: String?
        /// Without the @.
        var instagram: String?
        var website: String?

        var isEmpty: Bool { self == Details() }

        static func clean(_ raw: [String: String]) -> Details {
            var d = Details()
            d.work = raw["work"]
            d.school = raw["school"]
            d.from = raw["from"]
            d.phone = phone(raw["phone"])
            d.email = email(raw["email"])
            d.linkedin = handle(raw["linkedin"], after: "/in/")
            d.instagram = handle(raw["instagram"], after: "instagram.com/")
            d.website = website(raw["website"])
            return d
        }

        /// Keeps the digits and a leading +; fewer than 7 digits is a mishearing.
        static func phone(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let digits = raw.filter(\.isNumber)
            guard (7...15).contains(digits.count) else { return nil }
            return raw.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" + digits : digits
        }

        /// "priya at gmail dot com" is the model's job; this only rejects what isn't an address.
        static func email(_ raw: String?) -> String? {
            guard let raw = raw?.lowercased().replacingOccurrences(of: " ", with: ""),
                  let at = raw.firstIndex(of: "@"), raw[at...].contains("."), at != raw.startIndex else { return nil }
            return raw
        }

        /// A URL, "@name" or a bare name, down to the name.
        static func handle(_ raw: String?, after marker: String) -> String? {
            guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
            if let r = s.range(of: marker, options: .caseInsensitive) { s = String(s[r.upperBound...]) }
            s = String(s.split(whereSeparator: { "/?#".contains($0) }).first ?? "")
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
            guard !s.isEmpty, !s.contains(" "), s.count <= 60 else { return nil }
            return s
        }

        static func website(_ raw: String?) -> String? {
            guard var s = raw?.trimmingCharacters(in: .whitespaces).lowercased(), s.contains("."), !s.contains(" ") else { return nil }
            for prefix in ["https://", "http://", "www."] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
            while s.hasSuffix("/") { s.removeLast() }
            return s.isEmpty ? nil : s
        }
    }

    struct Result: Equatable {
        var skip = false
        var summary: String?
        var label: String?
        var hook: String?
        var topics: [String] = []
        var name: String?
        var facts: [String] = []
        var followups: [Followup] = []
        var details = Details()
        var outdated: [String] = []
    }

    static let prompt = """
    You keep a personal CRM for the wearer of AR glasses. You get the transcript of one in-person \
    conversation that just ended, from live speech recognition (expect misheard words). Lines are \
    tagged ME (the wearer) and THEM (the other person), or SPEAKER labels when that wasn't settled.

    Reply with one JSON object with exactly these keys:

    "skip": true when there was no real conversation worth remembering: only greetings, noise, \
    or the wearer talking to the glasses. Otherwise false.

    "summary": one sentence, at most 20 words, past tense, what the two of you actually talked \
    about. Specific nouns over vague ones ("Compared LoRA fine-tuning costs; Avi's applying to \
    Jane Street"), never "had a nice chat". Never name the wearer; say "you" if needed.

    "label": who THEM is in at most 4 words, lowercase, from what they said: "evals startup \
    founder", "berkeley eecs junior". null if unclear.

    "hook": the single most useful thing to recall next time you see them, at most 5 words, \
    lowercase: "asked about hiring", "moving to new york". null if nothing stands out.

    "topics": up to 3 short topic labels, 1-3 words each.

    "name": THEM's first name if they said it, else null.

    "facts": ["..."]
      Durable things THEM revealed about themselves worth remembering next time: job, school, \
    projects, plans, where they're from or going, interests. At most 10 words each, at most 3, \
    most useful first. Never about the wearer, never anything already in "Known", never what was \
    merely discussed. Often [].

    "followups": [{"text": "...", "owner": "me" | "them", "due_in_days": integer or null}]
      Only commitments someone actually made or a next step both agreed on ("I'll send you the \
    deck", "let's get coffee next week", "I'll intro you to Priya"). Never invent one, never a \
    generic "stay in touch". "text" is written from the wearer's side, at most 10 words, and \
    always names THEM: "Send Avi the pitch deck", "Text Avi your cousin's number" (owner me); \
    "Avi sends you his deck", "Avi intros you to Priya" (owner them). Whoever said "I'll" owns it. \
    "due_in_days" only when a time was said, counted from the conversation's date (tomorrow = 1, \
    next week = 7, later today = 0); else null. At most 3. Usually [].

    "details": {"work", "school", "from", "phone", "email", "linkedin", "instagram", "website"}
      Only what THEM said about themselves in this conversation; leave out every key they didn't \
    say. "work": role and company, "ML engineer at Stripe". "school": "Berkeley EECS '27". \
    "from": a city or country. Contact details only when spelled out or clearly given: write \
    spoken forms as written ("priya at gmail dot com" = "priya@gmail.com", "four one five..." = \
    digits), "linkedin" and "instagram" are the handle or URL they gave. Often {}.

    "outdated": entries of "Known" that this conversation showed are no longer true (they \
    changed jobs, moved, graduated), copied exactly. Their replacement goes in "facts" or \
    "details". Usually [].
    """

    static func message(_ input: Input) -> String {
        let with = input.with
            ?? (input.name.map { "someone not in the contacts who said they're \($0)" } ?? "someone not recognised")
        return """
        Conversation date: \(input.when.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute()))
        Wearer: \(input.wearer)
        With: \(with)
        Known about them: \(input.known.isEmpty ? "nothing yet" : input.known.joined(separator: "; "))
        Open follow-ups with them: \(input.owed.isEmpty ? "none" : input.owed.joined(separator: "; "))

        Transcript:
        \(input.transcript.joined(separator: "\n"))
        """
    }

    static func ask(_ input: Input, model: Aid.Model) async throws -> Result {
        let text = try await complete(system: prompt, message(input), model: model)
        guard let result = parse(text) else { throw LLM.Failure.unreadable(String(text.prefix(120))) }
        return result
    }

    static func complete(system prompt: String, _ message: String, model: Aid.Model) async throws -> String {
        var body: [String: Any] = [
            "model": model.model,
            "temperature": 0.2,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": message],
            ],
        ]
        if model.model.contains("gpt-oss") {
            body.merge(["max_tokens": 2000, "reasoning_effort": "low"]) { _, new in new }
        } else if model.provider == .cerebras, model.model.contains("qwen") {
            body.merge(["max_tokens": 700, "reasoning_effort": "none"]) { _, new in new }
        } else if model.provider == .muse {
            body.merge(["max_tokens": 1500, "reasoning_effort": "minimal"]) { _, new in new }
        } else {
            body["max_tokens"] = 700
        }
        if model.provider == .cerebras { body.removeValue(forKey: "response_format") }
        return try await LLM.complete(model.provider.endpoint, key: model.key, body: body, timeout: 25)
    }

    /// Lenient like `Coach.parse`: prose around the object, null for [], strings for numbers.
    static func parse(_ text: String) -> Result? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let json = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else { return nil }
        func clean(_ value: Any?) -> String? {
            guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
                  s.lowercased() != "null" else { return nil }
            return s
        }
        var result = Result()
        result.skip = json["skip"] as? Bool ?? false
        result.summary = clean(json["summary"])
        result.label = clean(json["label"])
        result.hook = clean(json["hook"])
        result.topics = ((json["topics"] as? [Any]) ?? []).compactMap(clean).prefix(3).map { $0 }
        result.name = clean(json["name"])
        result.facts = ((json["facts"] as? [Any]) ?? []).compactMap { item -> String? in
            clean(item) ?? (item as? [String: Any]).flatMap { clean($0["text"]) }
        }.prefix(3).map { $0 }
        result.followups = ((json["followups"] as? [Any]) ?? []).compactMap { item -> Followup? in
            guard let object = item as? [String: Any], let text = clean(object["text"]) else { return nil }
            let days = (object["due_in_days"] as? Int) ?? (object["due_in_days"] as? String).flatMap { Int($0) }
            return Followup(text: text, mine: (clean(object["owner"]) ?? "me").lowercased() != "them", dueInDays: days)
        }.prefix(3).map { $0 }
        if let details = json["details"] as? [String: Any] {
            result.details = Details.clean(details.compactMapValues { clean($0) ?? ($0 as? NSNumber).map { "\($0)" } })
        }
        result.outdated = ((json["outdated"] as? [Any]) ?? []).compactMap(clean)
        if !result.skip, result.summary == nil { return nil }
        return result
    }
}

/// What a conversation still going says about someone just met: enough to fill in their card.
struct Glance: Equatable {
    var name: String?
    var label: String?
    var facts: [String] = []

    static let prompt = """
    You fill in a contact card for the wearer of AR glasses while they talk to someone they just \
    met. You get the conversation so far, from live speech recognition (expect misheard words). \
    Lines are tagged ME (the wearer) and THEM (the other person), or SPEAKER labels when that \
    wasn't settled.

    Reply with one JSON object with exactly these keys:
    "name": THEM's name if they said it (first, plus last if said), else null.
    "label": who THEM is in at most 4 words, lowercase, from what they said: "evals startup \
    founder", "berkeley eecs junior". null if unclear.
    "facts": up to 3 durable things THEM said about themselves (job, school, project, where \
    they're from, plans, interests), at most 8 words each, most useful first, never anything in \
    "Known", never about the wearer. Often [].
    """

    static func ask(_ input: Recap.Input, model: Aid.Model) async throws -> Glance {
        let text = try await Recap.complete(system: prompt, Recap.message(input), model: model)
        guard let glance = parse(text) else { throw LLM.Failure.unreadable(String(text.prefix(120))) }
        return glance
    }

    static func parse(_ text: String) -> Glance? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let json = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else { return nil }
        func clean(_ value: Any?) -> String? {
            guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
                  s.lowercased() != "null" else { return nil }
            return s
        }
        return Glance(name: clean(json["name"]), label: clean(json["label"]),
                      facts: ((json["facts"] as? [Any]) ?? []).compactMap(clean).prefix(3).map { $0 })
    }
}
