import Foundation

// Who owns the lens (App/LensPolicy.swift) and how face ID seeds the aid (Aid.met).
var failures = 0
func check(_ condition: Bool, _ what: String) {
    if !condition { failures += 1; print("FAIL: \(what)") }
}

check(LensPolicy.mode(identifying: true, aidArmed: true) == .identity, "a press shows its progress")
check(LensPolicy.mode(identifying: false, confirming: true, aidArmed: true) == .identity, "so does Are you sure?")
check(LensPolicy.mode(identifying: false, aidArmed: true) == .split, "listening: aid on top, person at the bottom")
check(LensPolicy.mode(identifying: false, aidArmed: false) == .identity, "mic off: the face side alone")

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
