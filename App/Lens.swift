import Foundation

/// What the lens shows during a conversation. Three things, no more:
/// - `header`: who you're talking to, once they've said their name.
/// - `card`: one passing card — an answer, a definition or a research note — that times out.
/// - `followup`: a rare interjection, pinned while cards come and go: a definition that pops up for
///   eight seconds must not knock a good question off the display.
struct LensView: Equatable {
    var header: String?
    var card: Card?
    var followup: String?
    /// Slow work in flight (a tool, a lookup): a row each, under the card, with a countdown. The
    /// card slot stays free meanwhile, so a quick answer or a definition can show while an agent
    /// is still pulling the harder one.
    var working: [Work] = []

    /// The name alone isn't worth a glance; it only shows with a card, a suggestion or work.
    var isEmpty: Bool { card == nil && followup == nil && working.isEmpty }
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
    /// said; research is background that can wait.
    enum Kind: Int, Comparable {
        case research = 1, definition = 2, answer = 3
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
/// 1. The pinned follow-up is independent of the card slot. Only the coach replaces or clears it,
///    or it goes stale after `followupLife`.
/// 2. An answer takes the card slot immediately; it was asked for and is useless if late.
/// 3. Anything else waits its turn: it replaces the current card once that card has been up for
///    `minDwell` (`answerDwell` for a finished answer; never while one streams). Otherwise it
///    queues, and a queued card that waited longer than `maxWait` is dropped: an old definition
///    is worse than none.
/// 4. While the wearer talks (`hold`), nothing new goes up but answers: a card that lands mid-
///    sentence pulls their eyes off the person. It waits, and shows when they stop if still fresh.
struct Compositor {
    private(set) var view = LensView()

    static let ttl: [Card.Kind: TimeInterval] = [.answer: 12, .definition: 8, .research: 14]
    static let minDwell: TimeInterval = 2.5
    static let answerDwell: TimeInterval = 5
    /// How long a card may wait for the slot (or for the wearer to stop talking) before it is
    /// stale. In a fast conversation a definition is worth little five seconds on.
    static let maxWait: [Card.Kind: TimeInterval] = [.answer: 3, .definition: 5, .research: 15]
    /// An interjection is for the wearer's next turn (Aid clears it once they've spoken); if they
    /// don't take it, it fades.
    static let followupLife: TimeInterval = 20

    private var shownAt = Date.distantPast
    private var expiresAt: Date?
    private var waiting: [(card: Card, since: Date)] = []
    private var pinnedAt = Date.distantPast
    /// While the wearer talks nothing new goes up except answers; a suggestion waits here.
    private(set) var holding = false
    private var heldFollowup: (text: String, since: Date)?

    mutating func show(_ card: Card, at now: Date) {
        if holding, card.kind != .answer, view.card?.id != card.id {
            waiting.removeAll { $0.card.kind == card.kind && $0.card.title == card.title }
            waiting.append((card, now))
            return
        }
        if let current = view.card {
            if current.id == card.id, current.kind == card.kind {
                // The same card, updated: an answer streaming in, or finishing.
                view.card = card
                if card.live {
                    expiresAt = nil
                } else if current.live || expiresAt == nil {
                    expiresAt = now.addingTimeInterval(Self.ttl[card.kind] ?? 8)   // just finished: start its clock
                }
                return
            }
            if !replaces(current, with: card, at: now) {
                waiting.removeAll { $0.card.kind == card.kind && $0.card.title == card.title }
                waiting.append((card, now))
                if waiting.count > 3 { waiting.removeFirst() }
                return
            }
        }
        put(card, at: now)
    }

    /// Take a card down early, e.g. an answer the model decided to SKIP.
    mutating func remove(id: Int, kind: Card.Kind, at now: Date) {
        waiting.removeAll { $0.card.id == id && $0.card.kind == kind }
        guard let current = view.card, current.id == id, current.kind == kind else { return }
        view.card = nil
        expiresAt = nil
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
        if let expiresAt, now >= expiresAt {
            view.card = nil
            self.expiresAt = nil
        }
        if view.followup != nil, now.timeIntervalSince(pinnedAt) >= Self.followupLife {
            view.followup = nil
        }
        guard !holding else { return }
        // A waiting card can also take over once the current one has had its minimum time up.
        if let current = view.card, let first = waiting.first, replaces(current, with: first.card, at: now) {
            waiting.removeFirst()
            put(first.card, at: now)
        }
        promote(at: now)
    }

    mutating func clear() {
        self = Compositor()
    }

    /// When `tick` next has something to do, if anything.
    var nextDeadline: Date? {
        var dates: [Date] = []
        if let expiresAt { dates.append(expiresAt) }
        if view.followup != nil { dates.append(pinnedAt.addingTimeInterval(Self.followupLife)) }
        if view.card == nil, !holding, let first = waiting.first { dates.append(first.since) }
        if let card = view.card, !waiting.isEmpty {
            dates.append(shownAt.addingTimeInterval(card.kind == .answer ? Self.answerDwell : Self.minDwell))
        }
        return dates.min()
    }

    // MARK: -

    private func replaces(_ current: Card, with card: Card, at now: Date) -> Bool {
        if card.kind == .answer { return true }
        // An answer is never bumped while it streams, and gets `answerDwell` to be read once done.
        if current.kind == .answer { return !current.live && now.timeIntervalSince(shownAt) >= Self.answerDwell }
        return now.timeIntervalSince(shownAt) >= Self.minDwell
    }

    private mutating func put(_ card: Card, at now: Date) {
        view.card = card
        shownAt = now
        expiresAt = card.live ? nil : now.addingTimeInterval(Self.ttl[card.kind] ?? 8)
    }

    private mutating func promote(at now: Date) {
        guard view.card == nil, !holding else { return }
        waiting.removeAll { now.timeIntervalSince($0.since) > Self.maxWait[$0.card.kind] ?? 5 }
        // Most important first, then oldest.
        guard let index = waiting.indices.max(by: { waiting[$0].card.kind < waiting[$1].card.kind }) else { return }
        let next = waiting.remove(at: index)
        put(next.card, at: now)
    }
}
