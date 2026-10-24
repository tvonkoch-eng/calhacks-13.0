// Mirrors Assistant's fire/refire decisions against a word-by-word hypothesis stream,
// to check we fire early, fire rarely, and end up asking the right question.
let refireGrowth = 2, maxFires = 3

func simulate(_ utterance: String) -> (fires: [String], firstFireAtWord: Int?) {
    let words = utterance.split(separator: " ").map(String.init)
    var fires: [String] = []
    var firedText = ""
    var firstAt: Int?
    func grew(_ t: String) -> Int { t.split(separator: " ").count - firedText.split(separator: " ").count }

    // Every prefix is a hypothesis; the endpoint arrives ~320 ms AFTER the last word, as a
    // separate step, so the complete clause gets one normal partial first.
    for n in 1...(words.count + 1) {
        let endpointed = n > words.count
        let partial = words.prefix(min(n, words.count)).joined(separator: " ")
        guard let c = QuestionGate.candidate(in: partial) else { continue }
        if endpointed {
            if firedText.isEmpty { fires.append(c.text); firstAt = firstAt ?? n }
            else if c.text != firedText, grew(c.text) >= refireGrowth { fires.append(c.text) }
            else if c.text != firedText { fires[fires.count - 1] = c.text }  // in-flight answer stands
            break
        }
        guard c.confidence == .strong else { continue }
        if firedText.isEmpty {
            fires.append(c.text); firedText = c.text; firstAt = n
        } else if fires.count < maxFires,
                  (c.text.hasPrefix(firedText) ? grew(c.text) >= refireGrowth
                                               : (grew(c.text) >= 1 || !firedText.hasPrefix(c.text))) {
            fires.append(c.text); firedText = c.text
        }
    }
    return (fires, firstAt)
}

let utterances = [
    "so how tall is the Eiffel Tower",
    "how many people live in Tokyo",
    "do you know what year the Berlin Wall fell",
    "what is the capital of Peru",
    "how are you doing today",
    "did you see the keynote this morning",
    "whats 17 times 23",
    "who was the first person to orbit the Earth",
]
var bad = 0
for u in utterances {
    let r = simulate(u)
    let total = u.split(separator: " ").count
    let personal = QuestionGate.candidate(in: u) == nil
    if personal {
        if !r.fires.isEmpty { bad += 1; print("FAIL fired on personal: \(u) -> \(r.fires)") }
        else { print("skip    \"\(u)\"") }
        continue
    }
    if r.fires.count > maxFires { bad += 1; print("FAIL too many fires: \(u) -> \(r.fires.count)") }
    guard let at = r.firstFireAtWord else { bad += 1; print("FAIL never fired: \(u)"); continue }
    let last = r.fires.last ?? ""
    let want = QuestionGate.candidate(in: u)!.text
    if last != want { bad += 1; print("FAIL final question wrong: got \"\(last)\" want \"\(want)\"") }
    print("fire x\(r.fires.count) at word \(at)/\(total)  \"\(u)\"  ->  \"\(last)\"")
}
print(bad == 0 ? "SPECULATION OK" : "\(bad) problems")
