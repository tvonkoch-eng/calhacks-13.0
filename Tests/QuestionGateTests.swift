// Expectation: nil = gate must not fire, else (clause, strong?)
let cases: [(String, String?, Bool)] = [
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
    // personal / social / rhetorical — must not fire
    ("How are you doing?", nil, false),
    ("Hey, how's it going", nil, false),
    ("What do you think about that", nil, false),
    ("Are you from around here?", nil, false),
    ("Did you see the keynote", nil, false),
    ("Can you pass me the charger", nil, false),
    ("Should we grab lunch", nil, false),
    ("Where are you from", nil, false),
    ("whats your name", nil, false),
    ("do you want coffee", nil, false),
    ("How was your flight", nil, false),
    // not questions
    ("The sun is really big.", nil, false),
    ("I went to Berlin last year", nil, false),
    ("", nil, false),
    // tail selection: answer the newest sentence, not an older one
    ("How big is the sun? It's huge. What about Jupiter?", "what about jupiter", true),
    ("I love Berlin. How far is it from Munich", "how far is it from munich", true),
]

var failures = 0
for (input, want, wantStrong) in cases {
    let got = QuestionGate.candidate(in: input)
    let ok: Bool
    if let want {
        ok = got?.text == want && (got?.confidence == .strong) == wantStrong
    } else {
        ok = got == nil
    }
    if !ok {
        failures += 1
        let g = got.map { "\"\($0.text)\" \($0.confidence)" } ?? "nil"
        print("FAIL  in: \"\(input)\"\n      want: \(want.map { "\"\($0)\" strong=\(wantStrong)" } ?? "nil")\n      got:  \(g)")
    }
}
print(failures == 0 ? "ALL \(cases.count) PASS" : "\(failures)/\(cases.count) FAILED")
