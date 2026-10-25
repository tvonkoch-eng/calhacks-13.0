import Foundation

/// Who owns the lens. While the aid listens the lens is split, always: the conversation aid on
/// top (an answer, a definition, a line to say, work in flight) and who you're talking to at the
/// bottom, sticky. Neither half ever replaces the other: a person turning back to you no longer
/// takes the whole lens for a bio and wipes the answer that was up. A press of Identify (and its
/// "Are you sure?") and the mic being off show the face side alone, as before. Pure, so the rules
/// are testable without glasses (Tests/LensPolicyTests.swift).
enum LensMode: Equatable {
    /// The identity HUD as the face side draws it: idle row, person card, or a message.
    case identity
    /// Aid on top, person at the bottom.
    case split
}

enum LensPolicy {
    static func mode(identifying: Bool, confirming: Bool = false, aidArmed: Bool) -> LensMode {
        identifying || confirming || !aidArmed ? .identity : .split
    }
}

/// Someone in the conversation, as the lens and the phone show them. The host fills `speaking`
/// from who said the last line (or is saying this one).
struct Member: Equatable {
    let id: String
    /// First name: three of them have to fit on one lens row.
    var name: String
    var headline: String
    var speaking = false
    /// What else is known about them, most telling first; the split lens shows what fits.
    var lines: [String] = []
    /// Full name, for the split lens's card.
    var fullName: String = ""
    /// Their share of the lens's width when two are up: half each while both are in frame; while
    /// one is held out of frame (waiting to time out), the one in view gets two-thirds.
    var share: CGFloat = 0.5
}
