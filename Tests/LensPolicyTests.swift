import Foundation

// Who owns the lens (App/LensPolicy.swift) and how face ID seeds the aid (Aid.met).
var failures = 0
func check(_ condition: Bool, _ what: String) {
    if !condition { failures += 1; print("FAIL: \(what)") }
}

func mode(identifying: Bool = false, known: Bool = false, around: Bool = false, since: TimeInterval = 60,
          armed: Bool = true, aid: Bool = false) -> LensMode {
    LensPolicy.mode(identifying: identifying, known: known, around: around, sinceIdentified: since,
                    bioHolds: 6, aidArmed: armed, aidEmpty: !aid)
}

check(mode(identifying: true, aid: true) == .identity, "a press shows its progress over an aid card")
check(mode(known: true, around: true, since: 1, aid: true) == .identity, "a fresh identification wins over an aid card")
check(mode(known: true, around: true, since: 7, aid: true) == .both, "after the bio, the aid card with who you're talking to")
check(mode(known: true, around: false, since: 7, aid: true) == .aid, "the person left: the aid card alone")
check(mode(aid: true) == .aid, "nobody known: the aid card alone")
check(mode(known: true, around: true, since: 7) == .compact, "aid quiet, person still here: one line")
check(mode() == .idle, "aid quiet, nobody known: just the Identify row")
check(mode(known: true, around: true, since: 7, armed: false) == .identity, "mic off: the full card stays, as before")
check(mode(armed: false) == .identity, "mic off, nobody: the face side's idle HUD")

MainActor.assumeIsolated {
    let aid = Aid(config: Aid.Config(wearer: "Toby"))
    aid.heard(line: "Hi, I'm Joaquin.", speaker: "B", level: -40)
    aid.met(name: "Joaquin Del Pego", label: "LegalTime AI", facts: ["UCSB · Computer Science"])
    check(aid.them.name == "Joaquin Del Pego" && aid.them.recognised, "face ID names them")
    check(aid.lens.header == "Joaquin Del Pego", "and heads the lens")
    check(aid.them.summary.contains("LegalTime AI") && aid.them.summary.contains("UCSB"), "the coach sees their background")
    aid.met(name: "Avi Shah", label: "Engineer", facts: [])
    check(aid.them.name == "Avi Shah" && !aid.them.facts.contains("UCSB · Computer Science"), "someone new replaces the profile")
}

print(failures == 0 ? "LENS POLICY OK" : "\(failures) failures")
exit(failures == 0 ? 0 : 1)
