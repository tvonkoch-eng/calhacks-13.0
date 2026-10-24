import Foundation

// Who said each line (App/Speakers.swift): the glasses' own mic, introductions, where the wearer
// was looking, and the default when none of that is conclusive.
var failures = 0
func check(_ condition: Bool, _ what: String) {
    if !condition { failures += 1; print("FAIL: \(what)") }
}

let t0 = Date(timeIntervalSince1970: 1_000_000)
func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

// Two people, glasses transcribing the wearer.
do {
    var s = Speakers(wearer: "Toby")
    s.roster = ["avi": "avi", "mira": "mira"]
    s.looking(at: "avi", at: at(0))
    s.ownVoice("so what are you working on these days", at: at(1.5))
    var v = s.resolve(label: "A", text: "So what are you working on these days?", start: at(0.5), end: at(2))
    check(v.who == .me && v.sure, "the glasses heard it: the wearer's line (\(v))")
    v = s.resolve(label: "B", text: "We're building a payments startup for small restaurants", start: at(3), end: at(6))
    check(v.who == .person("avi"), "a long line the glasses didn't hear, facing Avi: Avi's (\(v))")
    v = s.resolve(label: "B", text: "Mostly in the Bay Area right now, expanding soon", start: at(7), end: at(9))
    check(v.who == .person("avi"), "again")
    check(s.links["B"] == "avi", "two lines facing Avi link voice B to him")
    s.looking(at: nil, at: at(10))
    v = s.resolve(label: "B", text: "Honestly the hardest part has been hiring engineers", start: at(11), end: at(14))
    check(v.who == .person("avi"), "looking away, the voice still says Avi (\(v))")
    v = s.resolve(label: "A", text: "ok", start: at(15), end: at(15.5))
    check(v.who == .me, "too short to check, but voice A has been the wearer (\(v))")
}

// Three people: the wearer looks at whoever is talking.
do {
    var s = Speakers(wearer: "Toby")
    s.roster = ["avi": "avi", "mira": "mira"]
    s.ownVoice("hey", at: at(0))   // the glasses are listening
    s.looking(at: "avi", at: at(0))
    _ = s.resolve(label: "B", text: "I think the market for this is enormous honestly", start: at(1), end: at(4))
    s.looking(at: "mira", at: at(4.5))
    _ = s.resolve(label: "C", text: "I disagree, regulation is going to slow everything down", start: at(5), end: at(8))
    s.looking(at: "avi", at: at(8.5))
    _ = s.resolve(label: "B", text: "Regulation follows adoption, it always has in payments", start: at(9), end: at(12))
    s.looking(at: "mira", at: at(12.5))
    _ = s.resolve(label: "C", text: "Tell that to the crypto exchanges in New York", start: at(13), end: at(15))
    check(s.links["B"] == "avi" && s.links["C"] == "mira", "each voice linked to the face it was said to (\(s.links))")
    // Mira speaks while the wearer is still looking at Avi: the voice wins over the gaze.
    s.looking(at: "avi", at: at(16))
    let v = s.resolve(label: "C", text: "What does the GENIUS Act actually require from issuers?", start: at(17), end: at(19))
    check(v.who == .person("mira"), "Mira's question, though the wearer looked at Avi (\(v))")
}

// Introductions.
do {
    var s = Speakers(wearer: "Toby")
    s.roster = ["mira": "mira"]
    var v = s.resolve(label: "C", text: "Hi, I'm Mira, I run the robotics club", start: at(0), end: at(2))
    check(v.who == .person("mira") && v.sure, "I'm Mira links her voice (\(v))")
    v = s.resolve(label: "A", text: "Nice to meet you, I'm Toby", start: at(3), end: at(4))
    check(v.who == .me && v.sure, "I'm Toby is the wearer")
    v = s.resolve(label: "A", text: "What do you all build?", start: at(5), end: at(6))
    check(v.who == .me, "and stays the wearer")
}

// No glasses transcription at all: default to the other person, whoever is in view.
do {
    var s = Speakers(wearer: "Toby")
    s.looking(at: "avi", at: at(0))
    var v = s.resolve(label: "A", text: "What is the capital of Germany?", start: at(1), end: at(2))
    check(v.who == .person("avi") && !v.sure, "no evidence: the person in front of you (\(v))")
    check(s.wearerTalking(at: at(2)) == nil, "no live signal without the glasses' mic")
    s.looking(at: nil, at: at(3))
    v = s.resolve(label: "D", text: "Where is the closest Target?", start: at(4), end: at(5))
    check(v.who == .someone, "nobody in view: someone, never the wearer (\(v))")
    s.markMe("A")
    v = s.resolve(label: "A", text: "Anyway I should get going", start: at(6), end: at(7))
    check(v.who == .me && v.sure, "That was me sticks to the voice")
}

// Live: the glasses hear the wearer right now.
do {
    var s = Speakers(wearer: "Toby")
    s.ownVoice("so I was thinking", at: at(0))
    check(s.wearerTalking(at: at(0.5)) == true, "words from the glasses half a second ago: wearer talking")
    check(s.wearerTalking(at: at(3)) == false, "quiet for a while: not the wearer")
}

// Glasses that hear everyone switch themselves off as a signal.
do {
    var s = Speakers(wearer: "Toby")
    for i in 0..<10 {
        let label = i % 2 == 0 ? "A" : "B"
        let text = "line number \(i) about payments regulation startups hiring"
        s.ownVoice(text, at: at(Double(i * 5) + 1))
        _ = s.resolve(label: label, text: text, start: at(Double(i * 5)), end: at(Double(i * 5) + 2))
    }
    check(!s.ownVoiceTrusted, "every voice matched: the glasses hear everyone, stop trusting them")
}

print(failures == 0 ? "ok" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
