import Foundation

// Who owns the lens (App/LensPolicy.swift) and how face ID seeds the aid (Aid.met).
var failures = 0
func check(_ condition: Bool, _ what: String) {
    if !condition { failures += 1; print("FAIL: \(what)") }
}

func mode(identifying: Bool = false, known: Bool = false, around: Bool = false, since: TimeInterval = 60,
          armed: Bool = true, aid: Bool = false) -> LensMode {
    LensPolicy.mode(identifying: identifying, known: known, around: around, sinceIdentified: since,
                    bioHolds: 10, aidArmed: armed, aidEmpty: !aid)
}

check(mode(identifying: true, aid: true) == .identity, "a press shows its progress over an aid card")
check(LensPolicy.mode(identifying: false, confirming: true, known: true, around: true, sinceIdentified: 60,
                      bioHolds: 10, aidArmed: true, aidEmpty: false) == .identity, "so does Are you sure?")
check(mode(known: true, around: true, since: 9, aid: true) == .identity, "the bio holds for ~10 s")
check(mode(known: true, around: true, since: 1, aid: true) == .identity, "a fresh identification wins over an aid card")
check(mode(known: true, around: true, since: 11, aid: true) == .both, "after the bio, the aid card with who you're talking to")
check(mode(known: true, around: false, since: 11, aid: true) == .aid, "the person left: the aid card alone")
check(mode(aid: true) == .aid, "nobody known: the aid card alone")
check(mode(known: true, around: true, since: 11) == .compact, "aid quiet, person still here: one line")
check(mode() == .idle, "aid quiet, nobody known: just the Identify row")
check(mode(known: true, around: true, since: 11, armed: false) == .identity, "mic off: the full card stays, as before")
check(mode(armed: false) == .identity, "mic off, nobody: the face side's idle HUD")

// Several things at once: work rows sit under the card slot and never take it.
do {
    let t0 = Date()
    var lens = Compositor()
    lens.startWork(id: 1, label: "Researching the GENIUS Act", at: t0)
    check(!lens.view.isEmpty && lens.view.card == nil, "work alone keeps the lens up")
    lens.show(Card(kind: .definition, title: "stablecoin", detail: "a token pegged to a currency", id: 2), at: t0.addingTimeInterval(1))
    check(lens.view.card?.title == "stablecoin" && lens.view.working.count == 1, "a quick definition shows while the lookup runs")
    check(lens.view.working[0].remaining(at: t0.addingTimeInterval(2.2)) == 6, "8 s countdown, whole seconds")
    check(lens.view.working[0].remaining(at: t0.addingTimeInterval(9)) == nil, "past the estimate: almost there")
    lens.startWork(id: 3, label: "Finding coffee nearby", at: t0)
    lens.startWork(id: 4, label: "Checking your calendar", at: t0)
    check(lens.view.working.map(\.id) == [3, 4], "at most two rows, newest kept")
    lens.endWork(id: 3)
    check(lens.view.working.map(\.id) == [4], "a finished lane takes its row away")
    lens.tick(at: t0.addingTimeInterval(40))
    check(lens.view.working.isEmpty, "a lane that never reports back is dropped")
}

MainActor.assumeIsolated {
    var config = Aid.Config()
    config.wearer = "Toby"
    let aid = Aid(config: config)
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
