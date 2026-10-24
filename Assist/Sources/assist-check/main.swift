import AssistCore
import Foundation

// Offline checks: the question gate, and the engine's fire / refire / carry decisions driven by
// scripted recognizer output against a fake answer source. No audio, no network, ~5 seconds.

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL  \(what)") }
}

// MARK: Gate

let gate: [(String, String?, Bool)] = [
    ("How big is the sun?", "how big is the sun", true),
    ("how big is the", "how big is the", false),
    ("how big", "how big", false),
    ("how many people live in", "how many people live in", false),
    ("So wait, how tall is the Eiffel Tower", "how tall is the eiffel tower", true),
    ("Yeah. Um, what year did the Berlin Wall fall", "what year did the berlin wall fall", true),
    ("Do you know how many people live in Tokyo", "how many people live in tokyo", true),
    ("Any idea what the GDP of Denmark is?", "what the gdp of denmark is", true),
    ("I wonder who invented the transistor", "who invented the transistor", true),
    ("Did the Roman Empire use concrete?", "did the roman empire use concrete", true),
    ("Is Mount Everest still growing", "is mount everest still growing", true),
    ("whats 17 times 23", "whats 17 times 23", true),
    ("How are you doing?", nil, false), ("Hey, how's it going", nil, false),
    ("What do you think about that", nil, false), ("Are you from around here?", nil, false),
    ("Did you see the keynote", nil, false), ("Can you pass me the charger", nil, false),
    ("Should we grab lunch", nil, false), ("Where are you from", nil, false),
    ("whats your name", nil, false), ("do you want coffee", nil, false),
    ("How was your flight", nil, false), ("The sun is really big.", nil, false),
    ("I went to Berlin last year", nil, false), ("", nil, false),
    ("How big is the sun? It's huge. What about Jupiter?", "what about jupiter", true),
    ("I love Berlin. How far is it from Munich", "how far is it from munich", true),
]
for (input, want, strong) in gate {
    let got = QuestionGate.candidate(in: input)
    if let want {
        check(got?.text == want && (got?.confidence == .strong) == strong,
              "gate \"\(input)\" want \"\(want)\" strong=\(strong), got \(got.map { "\"\($0.text)\" \($0.confidence)" } ?? "nil")")
    } else {
        check(got == nil, "gate \"\(input)\" should be nil, got \"\(got?.text ?? "")\"")
    }
}
check(QuestionGate.candidate(in: "who invented telephone", settled: true)?.confidence == .strong, "3-word wh question with a noun is strong")
check(QuestionGate.candidate(in: "what do you", settled: true)?.confidence != .strong, "'what do you' is not strong")
check(QuestionGate.candidate(in: "Like, we're having a conversation, like, how's your run?") == nil, "'we're … how's your run' is personal, not an aux question")
check(QuestionGate.candidate(in: "We're going to the park later") == nil, "'we're going' is a statement, not 'were going'")
check(QuestionGate.candidate(in: "I was in Berlin, how far is it from Munich?")?.text == "how far is it from munich", "question after a comma")
check(QuestionGate.candidate(in: "Oh, so fast I was?", settled: false)?.confidence != .strong, "bare '?' does not fire early")
check(QuestionGate.candidate(in: "what what's the capital of Peru")?.text == "whats the capital of peru", "restart 'what what's'")
check(QuestionGate.candidate(in: "Can you hear me?") == nil, "'can you hear me' is personal")
check(QuestionGate.candidate(in: "Yeah, do you do you know where the Presidio is?")?.text == "where the presidio is", "stuttered lead-in 'do you do you know'")
check(QuestionGate.candidate(in: "what what is the capital of Peru")?.text == "what is the capital of peru", "restart 'what what is'")
check(QuestionGate.candidate(in: "do you know do you know who wrote Dune?")?.text == "who wrote dune", "lead-in said twice")
check(QuestionGate.candidate(in: "How many Who won the World Cup?")?.text == "who won the world cup", "abandoned start 'how many who won'")
check(QuestionGate.candidate(in: "how do you know who won")?.text != "who won", "'how do you know who won' is not a restart")
for (t, want) in [("How many...", true), ("And this is all data that I can.", true), ("using?", true),
                  ("pretty", true), ("and make sure it can pick you up and it'll like...", true),
                  ("Okay.", false), ("Thanks.", false), ("Thank you.", false), ("Who won the World Cup?", false),
                  ("I believe at least.", false), ("Can you hear me?", false), ("Wow.", false)] {
    check(QuestionGate.endsMidThought(t) == want, "endsMidThought(\"\(t)\") should be \(want)")
}
check(QuestionGate.candidate(in: "Um, okay, we might need to speak kind of loudly, which maybe is a product", settled: false) == nil, "relative 'which' after a comma is not a question")
check(QuestionGate.candidate(in: "Um, okay, we might need to speak kind of loudly, which maybe is a product issue.") == nil, "comma sentence closed with a period is a statement")
check(QuestionGate.candidate(in: "So if I ask you now, when did Calhacks at Berkeley start?")?.text == "when did calhacks at berkeley start", "question after a comma still found")
for (q, local) in [("what time does it start", false), ("what time is it", true), ("whats the time", true),
                   ("what time it is", true), ("what date did the berlin wall fall", false),
                   ("whats the date today", true), ("what day is thanksgiving", false), ("what day is it", true)] {
    check((Answerer.local(q) != nil) == local, "local tier on \"\(q)\" should be \(local)")
}
check(Aside.worthAsking("It was like 30 degrees in Lisbon when we went."), "note: number + place is worth asking")
check(!Aside.worthAsking("I am so tired, I barely slept last night."), "note: small talk is not worth a request")
check(!Aside.worthAsking("Okay, cool."), "note: short lines skipped")
check(!QuestionGate.endsMidThought("Yo, yo. Where is Mirabelle Brown from?"), "question ending on a preposition is finished")
check(QuestionGate.endsMidThought("How tall is the?") || QuestionGate.candidate(in: "How tall is the?")?.unfinished == true, "'the?' still unfinished")
check(!QuestionGate.endsMidThought("Can you hear this?"), "'Can you hear this?' is finished")
check(QuestionGate.endsMidThought("And this is all data that I can."), "'…that I can.' still held")
check(Aside.said("RAG pipelines", in: "He kept talking about RAG pipelines the whole time."), "note topic said")
check(!Aside.said("Paddison Bonhams", in: "A view of my view of the Paddison Bonhauts."), "note topic not said")
// Word pieces: an unsettled hypothesis is judged without its last word.
check(QuestionGate.candidate(in: "how tall is the e", settled: false)?.confidence == .weak, "word piece 'the e' must not be strong")
check(QuestionGate.candidate(in: "how tall is the Eiffel T", settled: false)?.text == "how tall is the eiffel", "'Eiffel T' → judged as 'eiffel'")
check(QuestionGate.candidate(in: "How tall is the Eiffel Tower?", settled: false)?.confidence == .strong, "'?' closes it even unsettled")
check(QuestionGate.candidate(in: "How tall is the.")?.unfinished == true, "'How tall is the.' is unfinished")
check(QuestionGate.candidate(in: "Who wrote Dune?")?.unfinished == false, "'Who wrote Dune?' is finished")
check(QuestionGate.candidate(in: "Do you know what?")?.unfinished == true, "'Do you know what?' is unfinished")
check(QuestionGate.candidate(in: "Was in Berlin last summer.") == nil, "aux-led sentence closed with a period is a statement")
check(QuestionGate.candidate(in: "how tall is the eiff", settled: false)?.confidence == .strong, "'eiff' piece is good enough to ask")
print("gate: \(gate.count + 19) cases")

// MARK: Engine

struct Fake: AnswerSource {
    let latency: Double
    func local(_ q: String) -> String? { Answerer.local(q) }
    func stream(_ q: String, context: String, settled: Bool) -> AsyncThrowingStream<AnswerEvent, Error> {
        let latency = latency
        return AsyncThrowingStream { c in
            Task {
                try? await Task.sleep(for: .seconds(latency))
                if (q.split(separator: " ").count < 3 || q.contains("target")), !settled { c.yield(.incomplete) }
                else if q.contains("flight") { c.yield(.personal) }
                else if q == "who painted them" { c.yield(.personal) }
                else { c.yield(.text("answer to: \(q)")) }
                c.finish()
            }
        }
    }
}

/// (seconds after start, text, final)
typealias Script = [(Double, String, Bool)]

@MainActor
func play(_ script: Script, latency: Double = 0.08) async -> [Turn] {
    let zero = Date()
    let log = EventLog(echo: CommandLine.arguments.contains("-v"), now: { Date().timeIntervalSince(zero) })
    let engine = Engine(source: Fake(latency: latency), log: log, now: { Date().timeIntervalSince(zero) })
    for (at, text, final) in script {
        let wait = at - Date().timeIntervalSince(zero)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        engine.heard(text, final: final, audioEnd: final ? at - 0.3 : nil)
    }
    try? await Task.sleep(for: .seconds(2.2))
    return engine.turns.reversed()
}

/// Word-piece stream the way SpeechAnalyzer emits it, 120 ms apart, then the final.
func pieces(_ sentence: String, from start: Double, final: String? = nil) -> Script {
    var out: Script = []
    var t = start
    var text = ""
    for word in sentence.split(separator: " ") {
        let w = String(word)
        if w.count > 4 {
            out.append((t, text + w.prefix(2), false)); t += 0.06
        }
        text += w
        out.append((t, text, false)); t += 0.12
        text += " "
    }
    out.append((t + 0.4, final ?? text.trimmed, true))
    return out
}

let runs: [(String, Script, (([Turn]) -> String?))] = [
    ("fires mid-sentence and keeps one turn",
     pieces("So um how tall is the Eiffel Tower", from: 0, final: "So, how tall is the Eiffel Tower?"),
     { t in
        guard t.count == 1 else { return "\(t.count) turns" }
        guard t[0].state == .done, t[0].answer.contains("eiffel") else { return "answer \"\(t[0].answer)\" state \(t[0].state)" }
        guard let lead = t[0].lead, lead > 0 else { return "lead \(t[0].lead ?? -99) not positive" }
        return nil
     }),
    ("never asks about a word piece",
     pieces("how tall is the Eiffel Tower", from: 0),
     { t in t.first.map { $0.question.hasSuffix(" e") || $0.question.hasSuffix(" ei") } == true ? "asked on a piece: \(t[0].question)" : nil }),
    ("recognizer splits mid-question → carried into one question",
     [(0.0, "How tall", false), (0.15, "How tall is", false), (0.3, "How tall is the", false),
      (0.9, "How tall is the.", true),
      (1.4, "Eiffel", false), (1.55, "Eiffel Tower", false), (2.0, "Eiffel Tower?", true)],
     { t in
        guard t.count == 1 else { return "\(t.count) turns: \(t.map(\.question))" }
        return t[0].question == "how tall is the eiffel tower" && t[0].state == .done ? nil : "\"\(t[0].question)\" \(t[0].state)"
     }),
    ("recognizer closes \"Who painted?\" at a pause → still one question",
     [(0.0, "Wait, who", false), (0.12, "Wait, who painted", false), (0.5, "Wait, who painted?", true),
      (1.2, "Mona", false), (1.3, "Mona Lisa", false), (1.7, "Mona Lisa.", true)],
     { t in
        guard let last = t.last, last.question.contains("mona lisa"), last.state == .done else {
            return "\(t.map { "\($0.question) \($0.state)" })" }
        return nil
     }),
    ("WAIT that lands after the sentence closed → asked again as a finished question",
     [(0.0, "how many miles away is the target", false), (0.03, "How many miles away is the target?", true)],
     { t in t.count == 1 && t[0].state == .done && t[0].fires == 2 ? nil : "\(t.map { "\($0.question) \($0.state) fires=\($0.fires)" })" }),
    ("statement cut at a pause, question follows → joined, answered once",
     [(0.0, "And this is all data that I", false), (0.2, "And this is all data that I can.", true),
      (0.9, "using", false), (1.0, "using?", true), (1.8, "Uh, Grock", false), (2.2, "Uh, Grock, with a Q.", true),
      (3.6, "How many", false), (3.8, "How many...", true),
      (4.5, "who won", false), (4.7, "who won the World Cup", false), (4.9, "who won the World Cup?", true)],
     { t in
        let shown = t.filter { $0.state == .done }
        guard shown.count == 1, shown[0].question == "who won the world cup" else {
            return "\(t.map { "\($0.question) \($0.state)" })" }
        return nil
     }),
    ("'Who painted them?' then 'Mona Lisa.' → asked again as one question",
     [(0.0, "Who painted", false), (0.1, "Who painted them", false), (0.2, "Who painted them?", true),
      (0.9, "Mona", false), (1.0, "Mona Lisa.", true)],
     { t in t.count == 1 && t[0].state == .done && t[0].question.contains("mona lisa") ? nil : "\(t.map { "\($0.question) \($0.state)" })" }),
    ("statement held mid-thought, then a question → question still asked",
     [(0.0, "You don't feel like that", false), (0.1, "You don't feel like that.", true),
      (0.9, "Who was", false), (1.1, "Who was last year's winner of Cal Hacks", false),
      (1.3, "Who was last year's winner of Cal Hacks?", true)],
     { t in t.last?.question.hasPrefix("who was last years winner") == true && t.last?.state == .done ? nil : "\(t.map { "\($0.question) \($0.state)" })" }),
    ("held statement joined once, not chained into the next sentences",
     [(0.0, "But then this", false), (0.2, "But then this...", true),
      (1.0, "like over time", false), (1.2, "like over time...", true),
      (2.0, "Who painted the Mona Lisa", false), (2.2, "Who painted the Mona Lisa?", true)],
     { t in t.last?.question == "who painted the mona lisa" && t.last?.state == .done ? nil : "\(t.map { "\($0.question) \($0.state)" })" }),
    ("model WAIT on a fragment → re-asked with the full question",
     [(0.0, "Who", false), (0.1, "Who wrote?", false), (0.6, "Who wrote Dune?", true)],
     { t in t.count == 1 && t[0].state == .done && t[0].fires == 2 ? nil : "\(t.map { "\($0.question) \($0.state) fires=\($0.fires)" })" }),
    ("personal → nothing shown",
     pieces("how was your flight", from: 0),
     { t in t.allSatisfy { ![.done, .answering].contains($0.state) } ? nil : "showed an answer" }),
    ("not a question after all → early guess dropped",
     pieces("is it going to be okay with everyone if we", from: 0, final: "Is it going to be okay with everyone if we go."),
     { t in t.allSatisfy { ![.done, .answering].contains($0.state) || $0.answer.isEmpty == false } ? nil : "bad" }),
    ("two questions back to back → two turns",
     pieces("how big is the sun", from: 0, final: "How big is the sun?") + pieces("what about the moon", from: 1.6, final: "What about the moon?"),
     { t in t.count == 2 ? nil : "\(t.count) turns" }),
    ("local tier: arithmetic answers with no network",
     pieces("what is 17 times 23", from: 0, final: "What is 17 times 23?"),
     { t in t.last?.answer == "391" ? nil : "got \(t.map(\.answer))" }),
]

for (name, script, verdict) in runs {
    let turns = await play(script)
    if let problem = verdict(turns) {
        failures += 1
        print("FAIL  engine: \(name): \(problem)")
        for t in turns { print("        \"\(t.question)\" \(t.state) fires=\(t.fires) \"\(t.answer)\"") }
    } else {
        print("ok    engine: \(name)")
    }
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
