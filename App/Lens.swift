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

    /// The name alone isn't worth a glance; it only shows with a card or a suggestion.
    var isEmpty: Bool { card == nil && followup == nil }
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
struct Compositor {
    private(set) var view = LensView()

    static let ttl: [Card.Kind: TimeInterval] = [.answer: 12, .definition: 8, .research: 14]
    static let minDwell: TimeInterval = 2.5
    static let answerDwell: TimeInterval = 5
    static let maxWait: TimeInterval = 8
    /// An interjection is for the moment it was offered; then it fades.
    static let followupLife: TimeInterval = 45

    private var shownAt = Date.distantPast
    private var expiresAt: Date?
    private var waiting: [(card: Card, since: Date)] = []
    private var pinnedAt = Date.distantPast

    mutating func show(_ card: Card, at now: Date) {
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

    /// `nil` or empty clears the suggestion.
    mutating func pin(_ followup: String?, at now: Date) {
        let text = followup?.trimmingCharacters(in: .whitespacesAndNewlines)
        view.followup = (text?.isEmpty ?? true) ? nil : text
        pinnedAt = now
    }

    mutating func setHeader(_ header: String?) {
        view.header = header
    }

    /// Expire what's due and promote what's waiting. Call at `nextDeadline`, or whenever.
    mutating func tick(at now: Date) {
        if let expiresAt, now >= expiresAt {
            view.card = nil
            self.expiresAt = nil
        }
        if view.followup != nil, now.timeIntervalSince(pinnedAt) >= Self.followupLife {
            view.followup = nil
        }
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
        guard view.card == nil else { return }
        waiting.removeAll { now.timeIntervalSince($0.since) > Self.maxWait }
        // Most important first, then oldest.
        guard let index = waiting.indices.max(by: { waiting[$0].card.kind < waiting[$1].card.kind }) else { return }
        let next = waiting.remove(at: index)
        put(next.card, at: now)
    }
}
