import CoreLocation
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
let third = Card(kind: .definition, title: "ColPali", detail: "searches page images directly", id: 3)
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
    lens.show(third, at: at(10))
    check(lens.view.card == third, "a third shows once the dwell has passed")
    var stale = Compositor()
    stale.show(answer("x", live: true), at: at(0))
    stale.show(definition, at: at(0))
    stale.remove(id: 9, kind: .answer, at: at(Compositor.maxWait[.definition]! + 1))
    check(stale.view.card == nil, "a definition that waited too long is dropped")
}

// Nothing new goes up while the wearer talks, except an answer.
do {
    var lens = Compositor()
    lens.hold(true, at: at(0))
    lens.show(definition, at: at(0.5))
    lens.pin("What made you pick CAR T?", at: at(0.6))
    check(lens.view.card == nil && lens.view.followup == nil, "held while the wearer talks")
    lens.show(answer("2,225 nautical miles", live: false), at: at(1))
    check(lens.view.card?.kind == .answer, "an answer still goes up")
    var late = Compositor()
    late.hold(true, at: at(0))
    late.show(definition, at: at(0))
    late.pin("What made you pick CAR T?", at: at(0))
    late.hold(false, at: at(2))
    check(late.view.card == definition && late.view.followup == "What made you pick CAR T?", "shown when they stop, if fresh")
    var stale = Compositor()
    stale.hold(true, at: at(0))
    stale.show(definition, at: at(0))
    stale.hold(false, at: at(Compositor.maxWait[.definition]! + 1))
    check(stale.view.card == nil, "dropped if they talked too long")
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
    check(QuestionGate.candidate(in: "Uh, congrats, how was it?") == nil, "a check-in about their experience is personal")
    check(QuestionGate.candidate(in: "Oh, no way, like live captions?") == nil, "a reaction with a question mark is not a question")
    check(QuestionGate.candidate(in: "How was the Eiffel Tower built?") != nil, "but a factual how-was question passes")
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
    check(Talk.speaksForWearer("No, this is my first hackathon."), "a reply on the wearer's behalf is refused")
    check(Talk.speaksForWearer("I'm working on the aid myself"), "so is a claim about the wearer")
    check(!Talk.speaksForWearer("What roles are you hiring for?"), "a question to them is fine")
    check(Talk.same("was a paralegal for two years", "paralegal for two years"), "near-duplicate facts")
    check(Talk.mentioned("tumor microenvironment", in: Talk.normalized("notoriously hard because of the tumor microenvironment")),
          "a term in the newest line counts")
    check(!Talk.mentioned("LLM-as-a-judge", in: Talk.normalized("we just closed our seed lux led it")), "an old term does not")
    check(Talk.mentioned("LoRA adapter", in: Talk.normalized("we fine tune a lawyer adapter on contracts")),
          "a misheard term defined under its real name counts")
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

// Tools: the wake word, what counts as a tool question, and how results read.
do {
    check(Tools.command(in: "Lens, how far is the nearest Target?") == "how far is the nearest Target?", "wake word")
    check(Tools.command(in: "hey lens what's the weather like") == "what's the weather like", "hey lens")
    check(Tools.command(in: "The lens on these is great") == nil, "talking about lenses is not a command")
    check(Tools.command(in: "Lens.") == nil, "the wake word alone asks nothing")
    check(Tools.command(in: "Lens, weather?") == "weather?", "a one-word command")
    check(Tools.wants("how far is the nearest Target"), "places")
    check(Tools.wants("is it going to rain later"), "weather")
    check(Tools.wants("remind me to email Maya at six"), "reminders")
    check(Tools.wants("what's my next meeting"), "calendar")
    check(!Tools.wants("who wrote Dune"), "a plain question needs no tool")
    check(!Tools.wants("what's the training time of GPT-2"), "\"training\" is not \"rain\"")
    check(Tools.distance(503, us: true) == "0.3 mi", "miles: \(Tools.distance(503, us: true))")
    check(Tools.distance(120, us: true) == "400 ft", "feet: \(Tools.distance(120, us: true))")
    check(Tools.distance(503, us: false) == "500 m" && Tools.distance(1530, us: false) == "1.5 km", "metric")
    check(Tools.travel(503) == "~8 min walk", "walk, with streets 1.3× the straight line: \(Tools.travel(503))")
    check(Tools.travel(8000) == "~21 min drive", "drive: \(Tools.travel(8000))")
    check(Tools.placeQuery(in: "how far is the nearest Target?") == "target", "prefetch: nearest X")
    check(Tools.placeQuery(in: "is there a good coffee place near here?") == "coffee place", "prefetch: is there a X near")
    check(Tools.placeQuery(in: "who wrote Dune") == nil, "no place, no prefetch")
    check(Tools.wantsWeather("is it going to rain later") && !Tools.wantsWeather("what's the training time"), "weather prefetch")
    check(Answerer.local("what time is it in Tokyo") == nil, "another zone's time is not the local time")
    check(Answerer.local("what time is it") != nil, "the local time still is")
    let six = Tools.date("2026-10-24T18:00")
    check(six.map { Calendar.current.component(.hour, from: $0) } == 18, "local ISO time")
    check(Tools.date("2026-10-24T18:00:00Z") != nil && Tools.date("tomorrow") == nil, "zoned ISO; nonsense is nil")
}

// Research: offered as a tool only with a researcher behind it, and tried in order.
struct Fake: Researcher {
    let name: String
    let fails: Bool
    func research(_ query: String, context: String) async throws -> String {
        if fails { throw LLM.Failure.unreadable(name) }
        return "\(name): \(query)"
    }
}
do {
    let here = CLLocation(latitude: 37.788, longitude: -122.4075)
    let plain = DeviceTools(pinned: here)
    let deep = DeviceTools(pinned: here, researcher: Fake(name: "fetch", fails: false))
    let names = { (tools: DeviceTools) -> [String] in
        ((try? JSONSerialization.jsonObject(with: Data(tools.definitions.utf8)) as? [[String: Any]]) ?? [])
            .compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
    }
    check(names(plain) == ["nearby", "weather", "remind", "next_event"], "device tools: \(names(plain))")
    check(names(deep) == ["nearby", "weather", "remind", "next_event", "research"], "plus research: \(names(deep))")
}

// A refusal never reaches the lens; an answer that merely starts with I does.
do {
    check(Answerer.refuses("I don't have real-time Caltrain schedule information"), "refusal")
    check(Answerer.refuses("Sorry, I can't check that"), "apology")
    check(!Answerer.refuses("Isaac Newton") && !Answerer.refuses("IND: Investigational New Drug"), "facts starting with I")
}

// The coach's JSON, as models actually send it.
do {
    let one = Coach.parse(#"{"define": {"term": "LoRA", "meaning": "cheap fine-tuning"}, "suggest": null}"#)
    check(one?.define.count == 1 && one?.suggest == nil, "single definition object, nulls")
    let two = Coach.parse(#"Sure: {"define": [{"term":"SAFE","meaning":"a"},{"term":"pro rata","meaning":"b"},{"term":"x","meaning":"c"}], "suggest": "", "facts": ["sails"], "them": {"name": "Daniela"}}"#)
    check(two?.define.count == 1 && two?.define.first?.term == "SAFE", "one definition at a time, the first")
    check(two?.suggest == nil, "an empty suggestion is none")
    let say = Coach.parse(#"{"suggest": "What was the Transpac like?"}"#)
    check(say?.suggest == "What was the Transpac like?" && say?.define.isEmpty == true, "missing keys are fine")
    check(Coach.parse("no json here") == nil, "prose without JSON is rejected")
    let input = Coach.Input(wearer: "Toby", background: "finance student", known: "Priya · evals founder; Wearer promised: send the deck",
                            defined: [], suggested: ["How did the seed close?"], moment: "a silence", transcript: [])
    let message = Coach.message(input)
    check(message.contains("Wearer promised: send the deck") && message.contains("\"How did the seed close?\"")
          && message.contains("(nothing said yet)"), "the coach sees the record, past suggestions and an empty start")
    check(message.contains("Suggest now: yes (a silence)"), "a moment asks for a suggestion")
    var quiet = input
    quiet.moment = nil
    check(Coach.message(quiet).contains("Suggest now: no"), "no moment, no suggestion")
}

// Asking the glasses for a line to say, as opposed to asking them a question.
do {
    check(Talk.asksForSuggestion("what should I ask?"), "what should I ask")
    check(Talk.asksForSuggestion("what do I say next"), "what do I say")
    check(Talk.asksForSuggestion("give me something to talk about"), "give me something to")
    check(Talk.asksForSuggestion("help me out here"), "help me out")
    check(!Talk.asksForSuggestion("what should I eat nearby"), "a question about food is a question")
    check(!Talk.asksForSuggestion("what's her name again"), "a memory question is a question")
    check(!Talk.asksForSuggestion("how far is the nearest Target?"), "a place question is a question")
}

print(failures == 0 ? "AID OK" : "\(failures) failures")
exit(failures == 0 ? 0 : 1)
