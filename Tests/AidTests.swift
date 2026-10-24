import Foundation

// Offline checks on the conversation aid's pure rules: what the lens shows when, who's who, and
// how forgiving the coach's JSON parsing is. No network.

var failures = 0
func check(_ condition: Bool, _ what: String) {
    if !condition { failures += 1; print("FAIL \(what)") }
}

let t0 = Date(timeIntervalSince1970: 1_000_000)
func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
let definition = Card(kind: .definition, title: "ColBERT", detail: "late-interaction search model", id: 1)
let other = Card(kind: .definition, title: "LoRA", detail: "cheap fine-tuning for big models", id: 2)
let research = Card(kind: .research, title: "GENIUS Act", detail: "Signed July 2025; rules due 2026", id: 3)
func answer(_ text: String, live: Bool, id: Int = 9) -> Card { Card(kind: .answer, title: text, detail: "q", live: live, id: id) }

// The point of two slots: a definition never knocks the pinned follow-up off the lens.
do {
    var lens = Compositor()
    lens.pin("What made you switch to CS?", at: at(0))
    lens.show(definition, at: at(1))
    check(lens.view.card == definition && lens.view.followup == "What made you switch to CS?", "definition shows beside the follow-up")
    lens.tick(at: at(1 + Compositor.ttl[.definition]! + 0.1))
    check(lens.view.card == nil, "definition times out")
    check(lens.view.followup == "What made you switch to CS?", "follow-up survives the definition")
    lens.tick(at: at(Compositor.followupLife + 0.1))
    check(lens.view.followup == nil, "follow-up goes stale eventually")
}

// An answer was asked for out loud: it takes the slot at once and holds it while live.
do {
    var lens = Compositor()
    lens.show(definition, at: at(0))
    lens.show(answer("\u{2026}", live: true), at: at(0.5))
    check(lens.view.card?.kind == .answer, "answer preempts a definition immediately")
    lens.show(other, at: at(1))
    check(lens.view.card?.kind == .answer, "definition does not bump an answer")
    lens.tick(at: at(60))
    check(lens.view.card?.kind == .answer, "a live answer never times out")
    lens.show(answer("3,474 km across", live: false), at: at(61))
    check(lens.view.card?.title == "3,474 km across", "answer updates in place")
    lens.tick(at: at(61 + Compositor.ttl[.answer]! + 0.1))
    check(lens.view.card == nil, "finished answer times out; the queued definition is too old to show")
}

// Background waits its turn, and only for so long.
do {
    var lens = Compositor()
    lens.show(answer("1969", live: false), at: at(0))
    lens.show(definition, at: at(1))
    check(lens.view.card?.kind == .answer, "definition queues behind an answer")
    lens.remove(id: 9, kind: .answer, at: at(2))
    check(lens.view.card == definition, "queued definition shows when the answer goes")
    lens.show(other, at: at(3))
    check(lens.view.card == definition, "a second definition waits for the first's minimum dwell")
    lens.tick(at: at(2 + Compositor.minDwell + 0.1))
    check(lens.view.card == other, "then takes over")
    lens.show(research, at: at(10))
    check(lens.view.card == other || lens.view.card == research, "research shows once the dwell has passed")
    var stale = Compositor()
    stale.show(answer("x", live: true), at: at(0))
    stale.show(definition, at: at(0))
    stale.remove(id: 9, kind: .answer, at: at(Compositor.maxWait + 1))
    check(stale.view.card == nil, "a definition that waited too long is dropped")
}

// A finished answer gets read, then yields to what was just said.
do {
    var lens = Compositor()
    lens.show(answer("1969", live: false), at: at(0))
    lens.show(definition, at: at(1))
    lens.tick(at: at(Compositor.answerDwell - 0.1))
    check(lens.view.card?.kind == .answer, "a finished answer holds for its dwell")
    lens.tick(at: at(Compositor.answerDwell + 0.1))
    check(lens.view.card == definition, "then a waiting definition takes over")
}

// The question gate on things people actually say.
do {
    check(QuestionGate.candidate(in: "We're doing a legal tech thing") == nil, "\"we're doing\" is not \"were doing?\"")
    check(QuestionGate.candidate(in: "Yeah. We're building a conversation aid for smart glasses") == nil, "a statement after a sentence")
    check(QuestionGate.candidate(in: "What about you?") == nil, "\"what about you\" is social")
    check(QuestionGate.candidate(in: "Do you know how far it is from LA to Honolulu?")?.text == "how far it is from la to honolulu",
          "a real question still passes")
    check(QuestionGate.candidate(in: "Were you there?") == nil, "a real \"were\" question to the listener stays personal")
    check(QuestionGate.candidate(in: "how did you end") == nil, "\"how did you end (up…)\" is personal, even as a fragment")
    check(QuestionGate.candidate(in: "how do you say thank you in Japanese")?.confidence == .strong, "generic-you how-to still passes")
    check(QuestionGate.candidate(in: "Oh, interesting, how do you think about the regulation side?") == nil, "asking their view is personal")
}

// Who's who.
do {
    var roles = Roles()
    check(roles.tag("A") == "A" && !roles.known, "unknown roles keep raw labels")
    roles.heard("A", level: -30)
    roles.heard("B", level: -31)
    check(!roles.known, "a 1 dB gap is not enough to guess")
    roles.heard("B", level: -40)
    check(roles.wearer == "A" && !roles.sure, "louder speaker is the guessed wearer")
    check(roles.tag("A") == "ME" && roles.tag("B") == "THEM", "tags follow the guess")
    roles.lock("B")
    roles.heard("A", level: -10)
    check(roles.wearer == "B" && roles.sure, "a lock beats loudness")

    var intro = Roles()
    intro.heard("A", level: nil)
    intro.lock(them: "A")
    check(!intro.known, "the other person's label alone doesn't name the wearer yet")
    intro.heard("B", level: nil)
    check(intro.wearer == "B" && intro.sure, "whoever speaks next is the wearer")
    check(Talk.introducedName(in: "Hey, I'm Priya. Are you hacking this weekend?") == "Priya", "self-introduction")
    check(Talk.introducedName(in: "Yeah, I'm building a conversation aid") == nil, "\"I'm building\" is not a name")
    check(Talk.introducedName(in: "Nice to meet you, my name is Daniela.") == "Daniela", "my name is …")
}

// Text rules.
do {
    check(Talk.isBackchannel("Yeah."), "yeah is a backchannel")
    check(Talk.isBackchannel("Oh wow"), "oh wow is a backchannel")
    check(!Talk.isBackchannel("Yeah, I went to Berkeley."), "a real reply is not")
    check(!Talk.isBackchannel("No way, you sailed to Hawaii?"), "a question is not")
    check(Talk.echoes("So what made you switch from paralegal to computer science?", "What made you switch from paralegal to CS?"),
          "saying the suggestion counts as using it")
    check(!Talk.echoes("How was the wedding?", "What made you switch from paralegal to CS?"), "a different question does not")
    check(Talk.echoes("Congrats. What does Relit do?", "What does Relit do?"), "a short suggestion said word for word")
    check(!Talk.echoes("What do you do?", "What does Relit do?"), "but not a different short question")
    check(Talk.same("was a paralegal for two years", "paralegal for two years"), "near-duplicate facts")
    check(!Talk.same("flies back to Toronto Monday", "paralegal for two years"), "different facts")
    let s1 = Talk.sentences("Do you know how far it is? Anyway, I fly")
    check(s1.closed == ["Do you know how far it is?"] && s1.open == "Anyway, I fly", "splits closed and open sentences")
    let s2 = Talk.sentences("It's about 3.5 million people")
    check(s2.closed.isEmpty, "a decimal point does not end a sentence")
    let s3 = Talk.sentences("It took eleven days.")
    check(s3.closed.isEmpty && s3.open == "It took eleven days.", "a trailing period stays open in a partial")
    let s4 = Talk.sentences("How large is the moon?")
    check(s4.closed == ["How large is the moon?"], "a trailing question mark closes")
}

// The coach's JSON, as models actually send it.
do {
    let one = Coach.parse(#"{"define": {"term": "LoRA", "meaning": "cheap fine-tuning"}, "followup": null, "them": null, "facts": null, "research": null, "wearer": null}"#)
    check(one?.define.count == 1 && one?.followup == .keep && one?.facts == [], "single definition object, nulls")
    let two = Coach.parse(#"Sure: {"define": [{"term":"SAFE","meaning":"a"},{"term":"pro rata","meaning":"b"},{"term":"x","meaning":"c"}], "followup": "", "them": {"name": "Daniela", "label": null}, "facts": ["sails"], "research": "GENIUS Act status", "wearer": "b"}"#)
    check(two?.define.count == 2, "at most two definitions")
    check(two?.followup == .clear, "empty follow-up clears")
    check(two?.name == "Daniela" && two?.label == nil, "them fields")
    check(two?.research == "GENIUS Act status", "research")
    let say = Coach.parse(#"{"followup": "What was the Transpac like?"}"#)
    check(say?.followup == .say("What was the Transpac like?") && say?.define.isEmpty == true, "missing keys are fine")
    check(Coach.parse("no json here") == nil, "prose without JSON is rejected")
}

print(failures == 0 ? "AID OK" : "\(failures) failures")
exit(failures == 0 ? 0 : 1)
