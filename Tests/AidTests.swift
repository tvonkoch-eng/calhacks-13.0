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

// Cards stack, newest on top: a second answer no longer wipes the first.
do {
    var lens = Compositor()
    lens.show(answer("3,474 km across", live: false, id: 1), at: at(0))
    lens.show(answer("384,400 km away", live: false, id: 2), at: at(2))
    check(lens.view.cards.map(\.title) == ["384,400 km away", "3,474 km across"], "two answers both up, newest first")
    lens.tick(at: at(Compositor.ttl[.answer]! + 0.1))
    check(lens.view.cards.map(\.title) == ["384,400 km away"], "the older one drops off on its own clock")
    lens.show(answer("27 days", live: false, id: 3), at: at(3))
    lens.show(answer("1969", live: false, id: 4), at: at(4))
    check(lens.view.cards.map(\.title) == ["1969", "27 days", "384,400 km away"], "three answers up at once")
    lens.show(answer("Apollo 11", live: false, id: 5), at: at(5))
    check(lens.view.cards.map(\.title) == ["Apollo 11", "1969", "27 days"], "a fourth answer pushes out the oldest")
}

// An answer goes up at once and holds while live.
do {
    var lens = Compositor()
    lens.show(definition, at: at(0))
    lens.show(answer("\u{2026}", live: true), at: at(0.5))
    check(lens.view.card?.kind == .answer && lens.view.cards.count == 2, "answer goes on top of a definition")
    lens.show(other, at: at(1))
    lens.show(third, at: at(1.5))
    check(lens.view.cards.map(\.kind) == [.definition, .answer, .definition] && lens.view.cards[2] == definition,
          "a definition doesn't push out one that just went up")
    lens.tick(at: at(60))
    check(lens.view.cards.map(\.kind) == [.answer], "a live answer never times out")
    lens.show(answer("3,474 km across", live: false), at: at(61))
    check(lens.view.card?.title == "3,474 km across", "answer updates in place")
    lens.tick(at: at(61 + Compositor.ttl[.answer]! + 0.1))
    check(lens.view.cards.isEmpty, "finished answer times out; the queued definition is too old to show")
}

// A third card waits for the oldest to have had its time up, and only for so long.
do {
    var lens = Compositor()
    lens.show(answer("1969", live: false), at: at(0))
    lens.show(definition, at: at(1))
    lens.show(other, at: at(2))
    lens.show(third, at: at(2.5))
    check(lens.view.cards == [other, definition, answer("1969", live: false)], "full: the next definition queues")
    lens.tick(at: at(Compositor.answerDwell + 0.1))
    check(lens.view.cards == [third, other, definition], "then takes the finished answer's place")
    lens.remove(id: 1, kind: .definition, at: at(6))
    check(lens.view.cards == [third, other], "removing a card leaves the rest")
    var stale = Compositor()
    stale.show(answer("x", live: true, id: 7), at: at(0))
    stale.show(answer("y", live: true), at: at(0))
    stale.show(answer("z", live: true, id: 8), at: at(0))
    stale.show(definition, at: at(0))
    stale.remove(id: 9, kind: .answer, at: at(Compositor.maxWait[.definition]! + 1))
    check(stale.view.cards.map(\.title) == ["z", "x"], "a definition that waited too long is dropped")
    var twice = Compositor()
    twice.show(definition, at: at(0))
    twice.show(Card(kind: .definition, title: "ColBERT", detail: "again", id: 5), at: at(1))
    check(twice.view.cards.count == 1, "the same term twice shows once")
}

// Nothing new goes up while the wearer talks, except an answer.
do {
    var lens = Compositor()
    lens.hold(true, at: at(0))
    lens.show(definition, at: at(0.5))
    lens.pin("What made you pick CAR T?", at: at(0.6))
    check(lens.view.cards.isEmpty && lens.view.followup == nil, "held while the wearer talks")
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
    check(stale.view.cards.isEmpty, "dropped if they talked too long")
}

// The question gate on things people actually say.
do {
    check(QuestionGate.candidate(in: "We're doing a legal tech thing") == nil, "\"we're doing\" is not \"were doing?\"")
    check(QuestionGate.candidate(in: "Yeah. We're building a conversation aid for smart glasses") == nil, "a statement after a sentence")
    check(QuestionGate.candidate(in: "What about you?") == nil, "\"what about you\" is social")
    check(QuestionGate.candidate(in: "Do you know how far it is from LA to Honolulu?")?.text == "how far it is from la to honolulu",
          "a real question still passes")
    check(QuestionGate.candidate(in: "so I was telling him about the trip how many moons does Jupiter have")?.text
          == "how many moons does jupiter have", "a question buried in run-on talk")
    check(QuestionGate.candidate(in: "I was like I know what you mean honestly") == nil, "\"what you mean\" is not a question")
    check(QuestionGate.candidate(in: "he told me how much it cost them last year") == nil, "\"how much it cost\" is not a question")
    check(Talk.needsContext("how much did they raise"), "\"they\" needs the conversation")
    check(Talk.needsContext("when did that bill pass"), "\"that bill\" needs the conversation")
    check(!Talk.needsContext("how many moons does jupiter have"), "a self-contained question")
    check(!Talk.needsContext("is there a coffee place near here"), "\"is there\" points at nothing")
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

// Jarvis's loop on Claude: its own tool calls and their results translate to Claude blocks.
do {
    let call = Claude.message(["role": "assistant", "content": NSNull(), "tool_calls": [["id": "toolu_1", "type": "function",
                               "function": ["name": "weather", "arguments": "{\"when\": \"tonight\"}"]]]])
    let blocks = call["content"] as? [[String: Any]] ?? []
    check(blocks.count == 1 && blocks[0]["type"] as? String == "tool_use" && blocks[0]["id"] as? String == "toolu_1"
          && (blocks[0]["input"] as? [String: Any])?["when"] as? String == "tonight", "a tool call becomes tool_use")
    let result = Claude.message(["role": "tool", "tool_call_id": "toolu_1", "content": "57°F, clear"])
    let block = (result["content"] as? [[String: Any]])?.first
    check(result["role"] as? String == "user" && block?["type"] as? String == "tool_result"
          && block?["tool_use_id"] as? String == "toolu_1", "a tool result becomes tool_result")
}

// Jarvis's panel: steps tick off, the answer replaces them, then it goes on its own clock.
do {
    let t = Date(timeIntervalSince1970: 1_000_000)
    var c = Compositor()
    c.startJarvis("who should I follow up with?", at: t)
    c.jarvisStep("Reading your notes", at: t)
    c.jarvisStep("Searching: Priya Raman", at: t.addingTimeInterval(1))
    check(c.view.jarvis?.steps.map(JarvisPanel.line) == ["\u{2713} Reading your notes", "Searching: Priya Raman\u{2026}"], "steps tick off")
    check(c.view.jarvis?.header(at: t.addingTimeInterval(4)) == "Jarvis \u{00B7} 4s", "it counts up while it thinks")
    c.jarvisAnswer("Priya: you owe her the deck by tomorrow.", at: t.addingTimeInterval(5))
    check(c.view.jarvis?.thinking == false && c.view.jarvis?.header(at: t) == "Jarvis", "answered")
    check(c.nextDeadline == t.addingTimeInterval(5 + 12), "an answer stays 12 s: \(String(describing: c.nextDeadline))")
    c.tick(at: t.addingTimeInterval(17.1))
    check(c.view.jarvis == nil, "then it goes")
    c.startJarvis("x", at: t)
    c.tick(at: t.addingTimeInterval(121))
    check(c.view.jarvis == nil, "a think that never ends is dropped after two minutes")
}

// Tools: the wake word, what counts as a tool question, and how results read.
do {
    check(Tools.command(in: "Lens, how far is the nearest Target?") == "how far is the nearest Target?", "wake word")
    check(Tools.command(in: "hey lens what's the weather like") == "what's the weather like", "hey lens")
    check(Tools.command(in: "The lens on these is great") == nil, "talking about lenses is not a command")
    check(Tools.command(in: "Lens.") == nil, "the wake word alone asks nothing")
    check(Tools.command(in: "Lens, weather?") == "weather?", "a one-word command")
    check(Tools.command(in: "Jarvis, who did I meet today?") == "who did I meet today?", "Jarvis opens")
    check(Tools.command(in: "Um, hey Jarvis what did I promise Avi") == "what did I promise Avi", "filler before the name")
    check(Tools.command(in: "What's the weather, Jarvis?") == "What's the weather?", "Jarvis closes a question")
    check(Tools.command(in: "who here works at Google jarvis") == "who here works at Google", "closing, unpunctuated")
    check(Tools.command(in: "I just bought a new lens") == nil, "only Jarvis may close a command")
    check(Tools.command(in: "Jarvis.") == nil && Tools.wakeOnly("Jarvis.") && Tools.wakeOnly("hey Jarvis"), "the name alone wakes it")
    check(!Tools.wakeOnly("Jarvis, weather?"), "a request isn't a bare wake")
    check(Tools.byName("Jervis, who's next?") && !Tools.byName("Lens, weather?"), "by name, as misheard")
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
    check(two?.define.count == 3 && two?.define.first?.term == "SAFE", "up to three proper nouns, the first")
    let unknown = Coach.parse(#"{"define": [{"term": "Bauhaus", "meaning": null}, {"term": "Cal Hacks", "meaning": "a hackathon"}]}"#)
    check(unknown?.define.count == 2 && unknown?.define.first?.meaning == nil && unknown?.define.last?.meaning == "a hackathon", "no meaning is kept, for a search")
    check(two?.suggest == nil, "an empty suggestion is none")
    let say = Coach.parse(#"{"suggest": "What was the Transpac like?"}"#)
    check(say?.suggest == "What was the Transpac like?" && say?.define.isEmpty == true, "missing keys are fine")
    let ask = Coach.parse(#"{"ask": "How much did Figure AI raise in its latest round?", "define": [], "suggest": null}"#)
    check(ask?.ask == "How much did Figure AI raise in its latest round?", "a rebuilt request")
    check(Coach.parse("no json here") == nil, "prose without JSON is rejected")
    let extra = Coach.parse(#"{"ask": null, "define": [{"term": "GARCH model", "meaning": "volatility clustering"}], "insight": {"topic": "GARCH models", "query": "GARCH limits"}}}"#)
    check(extra?.define.first?.term == "GARCH model" && extra?.insight?.topic == "GARCH models", "one closing brace too many still parses")
    let input = Coach.Input(wearer: "Toby", background: "finance student", known: "Priya · evals founder; Wearer promised: send the deck",
                            defined: [], suggested: ["How did the seed close?"], moment: "a silence", transcript: [])
    let message = Coach.message(input)
    check(message.contains("Wearer promised: send the deck") && message.contains("\"How did the seed close?\"")
          && message.contains("(nothing said yet)"), "the coach sees the record, past suggestions and an empty start")
    check(message.contains("Suggest now: yes (a silence)"), "a moment asks for a suggestion")
    var quiet = input
    quiet.moment = nil
    check(!Coach.message(quiet).contains("Suggest now"), "no moment, no suggestion fields")
}

// Misheard and mixed-up: a statement isn't a request; the wearer's promise is offered, not asked about.
do {
    check(!Talk.asks("And we just raised a seed around, so we're hiring two evil engineers."), "a statement is not a request")
    check(Talk.asks("Thanks. You know what time the closing ceremonies start tomorrow"), "a question without its question mark")
    check(Talk.asks("Do you know Figure?"), "a plain question")
    let promise = "Toby promised to send her the hackathon demo video"
    check(Talk.isPromise(promise, by: "Toby"), "the wearer's promise")
    check(!Talk.isPromise("Dana promised to visit in May", by: "Toby"), "their promise isn't the wearer's")
    check(Talk.asksAbout(promise, in: "Did you catch the demo video?"), "asking them about the wearer's promise")
    check(Talk.asksAbout(promise, in: "Did you send the demo video?"), "asking them whether they sent it")
    check(!Talk.asksAbout(promise, in: "Want me to send the demo video?"), "offering it is fine")
    check(!Talk.asksAbout(promise, in: "Did you make it to Lisbon?"), "a different question is fine")
}

// Questions whose answer changes go to the web, not memory.
do {
    check(Talk.wantsNow("who won the most recent turing award"), "most recent")
    check(Talk.wantsNow("what's the latest on the GENIUS Act"), "latest")
    check(Talk.wantsNow("who is the current CEO of OpenAI"), "current")
    check(!Talk.wantsNow("who founded anthropic"), "a settled fact stays in memory")
    check(!Talk.wantsNow("how far is berkeley from san francisco"), "a distance stays in memory")
}

// Place questions in the plural go to the device tools too.
do {
    check(Tools.wants("What is like a popular Chinese restaurant near us?"), "near us is a place question")
    check(Tools.wants("anything good to eat around us"), "around us is a place question")
    check(Tools.wants("is there a coffee shop in the area"), "in the area is a place question")
    check(!Tools.wants("how far is Berkeley from San Francisco"), "between two named places is memory")
    check(Tools.wants("how far is the Golden Gate Bridge from here"), "from here needs the device")
    check(Tools.wants("how far is the nearest Target"), "the nearest needs the device")
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

// Ranked suggestions: the best goes up, the runners-up wait for the next lull.
do {
    let ranked = Coach.parse(#"{"define": [], "suggest": [{"say": "How did the Transpac go?", "score": 5}, {"say": "Who crewed with you?", "score": 3}, {"say": "Racing next year?", "score": 2}], "ask": null}"#)
    check(ranked?.suggest == "How did the Transpac go?" && ranked?.score == 5, "best suggestion and its score")
    check(ranked?.alternatives.map(\.say) == ["Who crewed with you?", "Racing next year?"]
          && ranked?.alternatives.map(\.score) == [3, 2], "runners-up in order, with scores")
    let strings = Coach.parse(#"{"suggest": ["What's next for Rillet?", "Hiring?"]}"#)
    check(strings?.suggest == "What's next for Rillet?" && strings?.score == nil && strings?.alternatives.map(\.say) == ["Hiring?"], "a plain list of lines")
    let none = Coach.parse(#"{"suggest": [], "define": []}"#)
    check(none?.suggest == nil && none?.alternatives.isEmpty == true, "an empty list is no suggestion")
}

// Insights: a topic and a fact, or nothing.
do {
    let one = Coach.parse(#"{"define": [], "insight": {"topic": "Humanoid robots", "query": "humanoid robot teleoperation share"}, "ask": null}"#)
    check(one?.insight?.topic == "Humanoid robots" && one?.insight?.query == "humanoid robot teleoperation share", "an insight is read")
    check(Coach.parse(#"{"insight": null}"#)?.insight == nil, "null is no insight")
    check(Coach.parse(#"{"insight": {"topic": "Robots"}}"#)?.insight?.query == "Robots", "no query: the topic is the search")
    // The part on lines to say goes out only when one is wanted.
    check(!Coach.prompt(suggesting: false).contains("\"suggest\""), "no suggestion rules when none is wanted")
    check(Coach.prompt(suggesting: true).contains("\"suggest\""), "suggestion rules when one is")
    let quiet = Coach.message(Coach.Input(wearer: "Toby", known: "", defined: [], suggested: ["x"], moment: nil, transcript: ["THEM: hi"]))
    check(!quiet.contains("Suggest now") && !quiet.contains("Already suggested"), "no suggestion fields when none is wanted")
}

// Claude behind the OpenAI-shaped requests every lane builds.
do {
    let body = Claude.body([
        "model": "claude-sonnet-5-5", "temperature": 0.3, "max_tokens": 220,
        "response_format": ["type": "json_object"],
        "messages": [["role": "system", "content": "rules"], ["role": "user", "content": "transcript"]],
    ])
    check(body["system"] as? String == "rules", "system message moves to system")
    check((body["messages"] as? [[String: String]])?.map { $0["role"] ?? "" } == ["user"], "only user turns stay in messages")
    check(body["temperature"] == nil && body["response_format"] == nil, "sampling and JSON mode are dropped")
    check((body["output_config"] as? [String: String])?["effort"] == "low", "no effort asked means low")
    check(body["max_tokens"] as? Int == 2048, "thinking gets room above a lane's tiny budget")

    let quick = Claude.body(["model": "claude-sonnet-5-5", "max_tokens": 48, "reasoning_effort": "none", "stream": true,
                             "messages": [["role": "user", "content": "q"]]])
    check((quick["thinking"] as? [String: String])?["type"] == "between_tools", "Sonnet 5.5 turns thinking off with between_tools")
    check(quick["max_tokens"] as? Int == 64 && quick["stream"] as? Bool == true, "no thinking keeps the budget small; streaming kept")
    let opus = Claude.body(["model": "claude-opus-5-5", "reasoning_effort": "none", "messages": []])
    check(opus["thinking"] == nil && (opus["output_config"] as? [String: String])?["effort"] == "low", "Opus can't stop thinking: low effort")

    let tools = Claude.body(["model": "claude-sonnet-5-5", "tool_choice": "auto", "messages": [],
                             "tools": [["type": "function", "function": ["name": "weather", "description": "the weather",
                                                                         "parameters": ["type": "object", "properties": [String: Any]()]]]]])
    let tool = (tools["tools"] as? [[String: Any]])?.first
    check(tool?["name"] as? String == "weather" && tool?["input_schema"] != nil, "function tools become Claude tools")
    check((tools["tool_choice"] as? [String: String])?["type"] == "auto", "tool choice auto")

    let reply = Claude.reply(["content": [["type": "thinking", "thinking": ""], ["type": "text", "text": "Sunny"],
                                          ["type": "tool_use", "name": "nearby", "input": ["query": "Target"]]]])
    check(reply.content == "Sunny", "text blocks are the content; thinking is skipped")
    check(reply.calls.first?.name == "nearby" && reply.calls.first?.arguments.contains("Target") == true, "tool_use becomes a call")
    check(Claude.delta(#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"391"}}"#) == "391", "stream text delta")
    check(Claude.delta(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hm"}}"#) == nil, "thinking deltas never reach the lens")
}

// OpenRouter: Cerebras first, Qwen's thinking off unless a lane asks for some.
do {
    let qwen = OpenRouter.adjust(["model": "qwen/qwen3.8-27b", "reasoning_effort": "none", "messages": []])
    check(qwen["reasoning_effort"] == nil && (qwen["reasoning"] as? [String: Bool])?["enabled"] == false, "no reasoning for a quick answer")
    check(((qwen["provider"] as? [String: Any])?["order"] as? [String])?.first == "cerebras", "Cerebras first")
    let oss = OpenRouter.adjust(["model": "openai/gpt-oss-120b", "reasoning_effort": "low"])
    check((oss["reasoning"] as? [String: String])?["effort"] == "low", "reasoning effort carried over")
    check((OpenRouter.adjust(["model": "qwen/qwen3.8-27b"])["reasoning"] as? [String: Bool])?["enabled"] == false, "Qwen defaults to no thinking")
    check(OpenRouter.adjust(["model": "qwen/qwen3.8-27b", "response_format": ["type": "json_object"]])["response_format"] == nil,
          "no JSON mode: it routes away from Cerebras")
}

// Exa: what needs the conversation to search, and findings as lines.
do {
    check(Exa.leans("how much did they raise"), "a pronoun needs the conversation")
    check(!Exa.leans("how much did Figure AI raise"), "a named subject searches as is")
    let lines = Exa.findings(["results": [
        ["title": "Figure raises $1B", "publishedDate": "2026-09-30T00:00:00Z", "highlights": ["Figure AI raised $1B at a $39B valuation."]],
        ["title": "Empty"],
    ]])
    check(lines == "- Figure raises $1B (2026-09-30): Figure AI raised $1B at a $39B valuation.", "one line per result with text")
}

print(failures == 0 ? "AID OK" : "\(failures) failures")
exit(failures == 0 ? 0 : 1)
