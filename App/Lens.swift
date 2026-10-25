import Foundation

/// What the lens shows during a conversation. Three things, no more:
/// - `header`: who you're talking to, once face ID or an introduction says.
/// - `cards`: up to `Compositor.maxCards` passing cards, newest first: answers (looked up or not)
///   and definitions. Two questions asked close together both stay up, the newer one on top,
///   instead of the second wiping the first; each times out on its own clock.
/// - `followup`: a suggestion of what to say next, pinned while cards come and go.
struct LensView: Equatable {
    var header: String?
    var cards: [Card] = []
    var followup: String?
    /// Slow work in flight (a tool, a lookup): a row each, under the cards, with a countdown. The
    /// cards stay free meanwhile, so a quick answer or a definition can show while an agent is
    /// still pulling the harder one.
    var working: [Work] = []

    /// Jarvis, asked by name: its own panel in the top of the lens (where a suggestion goes), the
    /// request, each step as it happens, then the answer.
    var jarvis: JarvisPanel?

    /// The newest card.
    var card: Card? { cards.first }

    /// The name alone isn't worth a glance; it only shows with a card, a suggestion or work.
    var isEmpty: Bool { cards.isEmpty && followup == nil && working.isEmpty && jarvis == nil }
}

/// What Jarvis is doing for the wearer, out in the open: slower and smarter than the passing
/// cards, so it shows its work ("Reading your notes", "Searching: Cal Hacks attendance") while
/// it thinks, the way a person would say "let me check".
struct JarvisPanel: Equatable {
    struct Step: Equatable {
        var label: String
        var done = false
    }

    var request: String
    var steps: [Step] = []
    var answer: String?
    var started: Date
    var answeredAt: Date?

    var thinking: Bool { answer == nil }

    /// "Jarvis · 4s" while it works, counting up: there's no honest estimate for a think.
    func header(at now: Date) -> String {
        thinking ? "Jarvis \u{00B7} \(max(1, Int(now.timeIntervalSince(started).rounded())))s" : "Jarvis"
    }

    /// A step as one lens line: done ones ticked, the current one trailing off.
    static func line(_ step: Step) -> String { step.done ? "\u{2713} \(step.label)" : "\(step.label)\u{2026}" }

    /// How long an answer stays: long enough to read twice, a little more for a longer one.
    static func life(of answer: String) -> TimeInterval {
        max(12, 6 + 0.45 * Double(answer.split(separator: " ").count))
    }
}

/// Something the aid is still getting: "Researching the GENIUS Act", started, about how long.
struct Work: Equatable {
    var id: Int
    var label: String
    var started: Date
    /// The countdown's length. 8 s unless the lane knows better.
    var eta: TimeInterval = Work.defaultETA
    static let defaultETA: TimeInterval = 8

    /// Whole seconds left, never below zero; nil once past the estimate ("almost there").
    func remaining(at now: Date) -> Int? {
        let left = eta - now.timeIntervalSince(started)
        return left > 0 ? Int(left.rounded(.up)) : nil
    }
}

struct Card: Equatable {
    /// Higher wins the slot. An answer was asked for out loud; a definition explains something just
    /// said.
    enum Kind: Int, Comparable {
        case insight = 1, definition = 2, answer = 3
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    var kind: Kind
    var title: String
    var detail: String = ""
    /// Still being written: an answer streaming in. A live card never times out.
    var live = false
    /// An answer updating in place keeps its id; everything else gets a fresh one.
    var id = 0
    /// A lens icon name for tool results: cart, forkKnife, cloud, bell, calendar…
    var icon: String?
}

/// Decides what is on the lens and for how long. Pure: the caller passes the clock in, so every
/// rule is testable without waiting (Tests/AidTests.swift).
///
/// The rules, in order of how much they matter:
/// 1. Cards stack, newest on top, at most `maxCards`. Each has its own clock (`ttl`) and drops off
///    by itself; the one under it moves up.
/// 2. An answer goes up immediately; it was asked for and is useless if late. With the stack
///    full it pushes out the oldest card, a finished one before one still streaming.
/// 3. A definition takes a free place, or the oldest card's once that has been up for `minDwell`
///    (`answerDwell` for a finished answer; never while one streams). Otherwise it queues, and a
///    queued card that waited longer than `maxWait` is dropped: an old definition is worse than none.
/// 4. While the wearer talks (`hold`), nothing new goes up but answers: a card that lands mid-
///    sentence pulls their eyes off the person. It waits, and shows when they stop if still fresh.
/// 5. The pinned follow-up is independent of the cards. Only the coach replaces or clears it, or
///    it goes stale after `followupLife`.
struct Compositor {
    private(set) var view = LensView()

    /// Two fit above the person on a 600 px panel; a third would push the newest one's detail off.
    /// Three: with definitions and insights coming every few sentences, two let most of them
    /// expire waiting for a slot. LensFit drops the oldest when they don't fit the top half.
    static let maxCards = 3
    static let ttl: [Card.Kind: TimeInterval] = [.answer: 15, .definition: 10, .insight: 10]
    static let minDwell: TimeInterval = 2.5
    static let answerDwell: TimeInterval = 5
    /// How long a card may wait for a place (or for the wearer to stop talking) before it is
    /// stale. In a fast conversation a definition is worth little five seconds on.
    /// Eight seconds for a definition or insight: the wearer's own turn holds new cards, and at 5 s
    /// most of what was found while they talked was thrown away unseen.
    static let maxWait: [Card.Kind: TimeInterval] = [.answer: 3, .definition: 8, .insight: 8]
    /// A suggestion is for the wearer's next turn (Aid clears it once they've spoken); if they
    /// don't take it, it fades.
    static let followupLife: TimeInterval = 20

    private struct Slot {
        var card: Card
        var shownAt: Date
        /// nil while the card is live (an answer streaming in).
        var expiresAt: Date?
    }

    /// Newest first, mirrored into `view.cards`.
    private var slots: [Slot] = [] {
        didSet { view.cards = slots.map(\.card) }
    }
    private var waiting: [(card: Card, since: Date)] = []
    private var pinnedAt = Date.distantPast
    /// While the wearer talks nothing new goes up except answers; a suggestion waits here.
    private(set) var holding = false
    private var heldFollowup: (text: String, since: Date)?

    mutating func show(_ card: Card, at now: Date) {
        if let index = slots.firstIndex(where: { $0.card.id == card.id && $0.card.kind == card.kind }) {
            // The same card, updated: an answer streaming in, or finishing. It keeps its place.
            let wasLive = slots[index].card.live
            slots[index].card = card
            if card.live {
                slots[index].expiresAt = nil
            } else if wasLive || slots[index].expiresAt == nil {
                slots[index].expiresAt = now.addingTimeInterval(Self.ttl[card.kind] ?? 8)   // just finished: start its clock
            }
            return
        }
        // Already up under another id (the same definition twice): nothing new to show.
        if slots.contains(where: { $0.card.kind == card.kind && $0.card.title == card.title }) { return }
        if holding, card.kind != .answer {
            wait(card, at: now)
            return
        }
        guard place(card, at: now) else {
            wait(card, at: now)
            return
        }
    }

    /// Take a card down early, e.g. an answer the model decided to SKIP.
    mutating func remove(id: Int, kind: Card.Kind, at now: Date) {
        waiting.removeAll { $0.card.id == id && $0.card.kind == kind }
        guard let index = slots.firstIndex(where: { $0.card.id == id && $0.card.kind == kind }) else { return }
        note("removed", slots.remove(at: index).card, "taken down early")
        promote(at: now)
    }

    /// At most two rows of work show; more than that is noise on a lens.
    static let maxWorking = 2

    mutating func startWork(id: Int, label: String, eta: TimeInterval = Work.defaultETA, at now: Date) {
        view.working.removeAll { $0.id == id }
        view.working.append(Work(id: id, label: label, started: now, eta: eta))
        if view.working.count > Self.maxWorking { view.working.removeFirst(view.working.count - Self.maxWorking) }
    }

    mutating func endWork(id: Int) {
        view.working.removeAll { $0.id == id }
    }

    /// Jarvis took a request: its panel replaces whatever it was showing.
    mutating func startJarvis(_ request: String, at now: Date) {
        view.jarvis = JarvisPanel(request: request, started: now)
    }

    /// The next step: the one before it is done.
    mutating func jarvisStep(_ label: String, at now: Date) {
        guard view.jarvis?.thinking == true else { return }
        for i in view.jarvis!.steps.indices { view.jarvis!.steps[i].done = true }
        view.jarvis!.steps.append(JarvisPanel.Step(label: label))
    }

    mutating func jarvisAnswer(_ answer: String, at now: Date) {
        guard view.jarvis != nil else { return }
        for i in view.jarvis!.steps.indices { view.jarvis!.steps[i].done = true }
        view.jarvis!.answer = answer
        view.jarvis!.answeredAt = now
    }

    mutating func clearJarvis() { view.jarvis = nil }

    /// `nil` or empty clears the suggestion.
    mutating func pin(_ followup: String?, at now: Date) {
        let text = followup?.trimmingCharacters(in: .whitespacesAndNewlines)
        if holding, let text, !text.isEmpty {
            heldFollowup = (text, now)
            return
        }
        heldFollowup = nil
        view.followup = (text?.isEmpty ?? true) ? nil : text
        pinnedAt = now
    }

    /// The wearer started or stopped talking. Letting go puts up whatever waited, if still fresh.
    mutating func hold(_ on: Bool, at now: Date) {
        guard on != holding else { return }
        holding = on
        guard !on else { return }
        if let held = heldFollowup {
            heldFollowup = nil
            if now.timeIntervalSince(held.since) <= Self.maxWait[.definition]! { pin(held.text, at: now) }
        }
        tick(at: now)
    }

    mutating func setHeader(_ header: String?) {
        view.header = header
    }

    /// Expire what's due and promote what's waiting. Call at `nextDeadline`, or whenever.
    mutating func tick(at now: Date) {
        // A lane that never reported back doesn't get to sit on the lens forever.
        view.working.removeAll { now.timeIntervalSince($0.started) > max($0.eta * 4, 30) }
        for slot in slots where slot.expiresAt.map({ now >= $0 }) ?? false {
            note("expired", slot.card, "shown \(String(format: "%.1f", now.timeIntervalSince(slot.shownAt))) s, ttl \(Self.ttl[slot.card.kind] ?? 8) s")
        }
        if slots.contains(where: { $0.expiresAt.map { now >= $0 } ?? false }) {
            slots.removeAll { $0.expiresAt.map { now >= $0 } ?? false }
        }
        if view.followup != nil, now.timeIntervalSince(pinnedAt) >= Self.followupLife {
            view.followup = nil
        }
        if let end = jarvisEnds, now >= end { view.jarvis = nil }
        promote(at: now)
    }

    mutating func clear() {
        let kept = journal
        self = Compositor()
        journal = kept
    }

    /// When `tick` next has something to do, if anything.
    var nextDeadline: Date? {
        var dates = slots.compactMap(\.expiresAt)
        if view.followup != nil { dates.append(pinnedAt.addingTimeInterval(Self.followupLife)) }
        if let end = jarvisEnds { dates.append(end) }
        if !holding, let first = waiting.first {
            dates.append(first.since.addingTimeInterval(Self.maxWait[first.card.kind] ?? 5))
            if slots.count < Self.maxCards {
                dates.append(first.since)
            } else if let oldest = slots.last, !oldest.card.live {
                dates.append(oldest.shownAt.addingTimeInterval(oldest.card.kind == .answer ? Self.answerDwell : Self.minDwell))
            }
        }
        return dates.min()
    }

    /// When Jarvis's panel goes: its answer's life after it landed, or two minutes of thinking
    /// (a lane that never answered doesn't get to sit there).
    private var jarvisEnds: Date? {
        guard let jarvis = view.jarvis else { return nil }
        if let answer = jarvis.answer, let at = jarvis.answeredAt { return at.addingTimeInterval(JarvisPanel.life(of: answer)) }
        return jarvis.started.addingTimeInterval(120)
    }

    // MARK: -

    /// Up on top if there's room or a card can make way for it; false when it has to wait.
    private mutating func place(_ card: Card, at now: Date) -> Bool {
        if slots.count >= Self.maxCards {
            guard let index = evictable(for: card, at: now) else { return false }
            let evicted = slots.remove(at: index).card
            note("pushedOut", evicted, "\(card.kind) \"\(card.title)\" needed the slot")
        }
        slots.insert(Slot(card: card, shownAt: now,
                          expiresAt: card.live ? nil : now.addingTimeInterval(Self.ttl[card.kind] ?? 8)), at: 0)
        note("shown", card, "\(slots.count) of \(Self.maxCards) slots")
        return true
    }

    /// What happened to each card, for the speed log: drained by Aid after each change.
    private(set) var journal: [[String: String]] = []
    private mutating func note(_ action: String, _ card: Card, _ reason: String) {
        journal.append(["action": action, "kind": "\(card.kind)", "title": card.title, "reason": reason])
    }
    mutating func drainJournal() -> [[String: String]] {
        defer { journal = [] }
        return journal
    }

    /// Which card goes to make room: the oldest one that has had its time up. An answer always
    /// gets a place: the oldest finished card, else the oldest of all.
    private func evictable(for card: Card, at now: Date) -> Int? {
        let oldestFirst = Array(slots.indices.reversed())
        if card.kind == .answer {
            return oldestFirst.first { !slots[$0].card.live } ?? oldestFirst.first
        }
        return oldestFirst.first { index in
            let slot = slots[index]
            if slot.card.live { return false }
            let dwell = slot.card.kind == .answer ? Self.answerDwell : Self.minDwell
            return now.timeIntervalSince(slot.shownAt) >= dwell
        }
    }

    private mutating func wait(_ card: Card, at now: Date) {
        waiting.removeAll { $0.card.kind == card.kind && $0.card.title == card.title }
        waiting.append((card, now))
        note("queued", card, holding ? "the wearer is talking" : "no free slot")
        if waiting.count > 3 { note("dropped", waiting.removeFirst().card, "queue full") }
    }

    private mutating func promote(at now: Date) {
        for entry in waiting where now.timeIntervalSince(entry.since) > Self.maxWait[entry.card.kind] ?? 5 {
            note("stale", entry.card, "waited past \(Self.maxWait[entry.card.kind] ?? 5) s")
        }
        waiting.removeAll { now.timeIntervalSince($0.since) > Self.maxWait[$0.card.kind] ?? 5 }
        guard !holding else { return }
        // Most important first, then oldest; stop at the first one that can't get a place.
        while let index = waiting.indices.max(by: { waiting[$0].card.kind < waiting[$1].card.kind }) {
            guard place(waiting[index].card, at: now) else { return }
            waiting.remove(at: index)
        }
    }
}
