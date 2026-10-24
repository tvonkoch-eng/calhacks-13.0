import Foundation

/// Who owns the lens: the face side (who you're looking at) or the conversation aid (what's being
/// said). Pure, so the rules are testable without glasses (Tests/AidTests.swift).
///
/// The rules, in order:
/// 1. A press of Identify shows its progress and result. The wearer asked.
/// 2. A fresh identification wins: the full background card stays up for `bioHolds` seconds,
///    even over an aid card. It is the one moment the wearer needs to read who this is.
/// 3. After that the aid takes over whenever it has something (an answer, a definition, a line to
///    say). If the person you're talking to is known and still in view, a small strip on top of
///    the aid card says who (`both`); otherwise the aid card alone (`aid`).
/// 4. With the aid listening and nothing to show, a known person shrinks to one line (`compact`);
///    nobody known in view leaves just the Identify row (`idle`).
/// 5. Mic off: the face side alone, as before (`identity`).
enum LensMode: Equatable {
    /// The identity HUD as the face side draws it: idle row, person card, or a message.
    case identity
    case aid
    case both
    case compact
    case idle
}

enum LensPolicy {
    static func mode(identifying: Bool, known: Bool, around: Bool, sinceIdentified: TimeInterval,
                     bioHolds: TimeInterval, aidArmed: Bool, aidEmpty: Bool) -> LensMode {
        if identifying { return .identity }
        if known, sinceIdentified < bioHolds { return .identity }
        let partner = known && around
        if !aidEmpty { return partner ? .both : .aid }
        guard aidArmed else { return .identity }
        return partner ? .compact : .idle
    }
}
