import Foundation

// The personal CRM (App/CRM.swift): the one save path, who a record is filed under, consent,
// default reminders, the lens line, and the conversation recorder. Fake clock, canned recap.
var failures = 0
func check(_ condition: Bool, _ what: String) {
    if !condition { failures += 1; print("FAIL: \(what)") }
}

let calendar = Calendar.current
let t0 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 15, minute: 0))!
func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
let tomorrow9 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 9))!

// Parsing: prose around the object, objects or strings for facts, numbers as strings, caps.
let parsed = Recap.parse("""
Here you go: {"skip": false, "summary": "Compared LoRA costs.", "label": "lse econ student",
 "hook": "applying to jane street", "topics": ["LoRA", "Jane Street", "recruiting", "extra"], "name": null,
 "facts": [{"text": "Applying to Jane Street"}, "Moving to New York", "Plays cricket", "Fourth"],
 "followups": [{"text": "Send Avi the pitch deck", "owner": "me", "due_in_days": "1"},
               {"text": "Avi intros you to Priya", "owner": "them", "due_in_days": null}]}
""")
check(parsed?.summary == "Compared LoRA costs." && parsed?.label == "lse econ student", "summary and label")
check(parsed?.hook == "applying to jane street", "hook")
check(parsed?.topics.count == 3 && parsed?.facts.count == 3, "topics and facts capped at 3")
check(parsed?.name == nil, "null name is nil")
check(parsed?.followups.first == Recap.Followup(text: "Send Avi the pitch deck", mine: true, dueInDays: 1), "string day count")
check(parsed?.followups.last?.mine == false && parsed?.followups.last?.dueInDays == nil, "their promise, no date")
check(Recap.parse("{\"skip\": true}")?.skip == true, "skip needs no summary")
check(Recap.parse("{\"skip\": false, \"topics\": []}") == nil, "no summary and no skip is unusable")
check(Recap.parse("sorry") == nil, "no JSON")

// Details: spoken contact info cleaned, mishearings dropped, unknown keys ignored.
let detailed = Recap.parse("""
{"skip": false, "summary": "Talked evals.", "details": {"work": "ML engineer at Stripe", "phone": "+1 (415) 555-0134",
 "email": "Priya@Gmail.com", "linkedin": "https://www.linkedin.com/in/priya-shah/", "instagram": "@priya.s",
 "website": "https://priya.dev/", "school": null, "shoe": "9"}, "outdated": ["Works at Ramp"]}
""")
let d = detailed?.details
check(d?.work == "ML engineer at Stripe" && d?.school == nil, "work kept, null school dropped")
check(d?.phone == "+14155550134" && d?.email == "priya@gmail.com", "phone digits, email lowercased")
check(d?.linkedin == "priya-shah" && d?.instagram == "priya.s" && d?.website == "priya.dev", "handles from URLs")
check(detailed?.outdated == ["Works at Ramp"], "outdated facts")
check(Recap.Details.phone("five five five") == nil && Recap.Details.phone("555 12") == nil, "a misheard number is dropped")
check(Recap.Details.email("priya at gmail") == nil, "not an address")
check(Recap.Details.handle("priya shah", after: "/in/") == nil && Recap.Details.handle("priya-shah", after: "/in/") == "priya-shah", "bare handle")
check(Recap.parse("{\"skip\": false, \"summary\": \"Hi.\"}")?.details.isEmpty == true, "no details by default")

check(CRM.due(0, from: t0) == at(7200), "due today = two hours later")
check(CRM.due(1, from: t0) == tomorrow9, "due tomorrow = 9 am")
check(Recap.message(Recap.Input(wearer: "Toby", when: t0, with: nil, name: "Priya", known: [], owed: [], transcript: []))
        .contains("Saturday"), "the prompt carries the weekday")

@MainActor func makeCRM(_ result: Recap.Result?, url: URL? = nil, now: Date = t0) -> CRM {
    UserDefaults.standard.removeObject(forKey: "crmGap")
    UserDefaults.standard.removeObject(forKey: "checkInDays")
    UserDefaults.standard.removeObject(forKey: "pendingDays")
    let crm = CRM(url: url, now: now)
    crm.filesStrangers = true
    crm.wearer = "Toby"
    crm.roster = { ["avi": CRM.Known(name: "Avi Shah", about: "LSE"), "joaquin": CRM.Known(name: "Joaquin Del Pego", about: "UCSB")][$0] }
    crm.retag = { $0 == "A" ? "ME" : $0 == nil ? "?" : "THEM" }
    crm.whereabouts = { "near Moscone, SF" }
    crm.recapper = { _ in
        guard let result else { throw LLM.Failure.unreadable("down") }
        return result
    }
    return crm
}

func settle() async { for _ in 0..<40 { await Task.yield() } }

// 1. The aid's record, matched by face ID: filed under the roster person.
await MainActor.run {
    let crm = makeCRM(nil)
    let avi = crm.save(Encounter(name: "Avi", label: "lse econ student", facts: ["Applying to Jane Street", "applying to jane street", "Plays cricket", "Likes F1", "Fourth"],
                                 followups: [Recap.Followup(text: "Send Avi the pitch deck"), Recap.Followup(text: "Avi intros you to Priya", mine: false, dueInDays: 7)],
                                 summary: "Compared LoRA costs.", hook: "applying to jane street", at: t0, ended: at(600),
                                 place: "near Union Square, SF", match: "avi"))
    check(avi == "avi" && crm.contacts.isEmpty, "a face match files under the roster person, no new contact")
    check(crm.facts(about: "avi").count == 2, "at most 3 facts, duplicates dropped")
    let open = crm.open(for: "avi")
    check(open.contains { $0.kind == .todo && $0.due == tomorrow9 }, "your promise is due tomorrow 9 am")
    check(open.contains { $0.kind == .waiting && $0.text == "Avi intros you to Priya" }, "their promise is tracked")
    check(open.filter { $0.kind == .checkIn }.count == 1, "one catch-up reminder")
    check(crm.conversations.first?.place == "near Union Square, SF", "place kept")
    check(crm.lastContext("avi") == "Avi · lse econ student · you said: send Avi the pitch deck", "lens line leads with what you owe")
    crm.complete(open.first { $0.kind == .todo }!.id)
    check(crm.lastContext("avi") == "Avi · lse econ student · waiting on: avi intros you to Priya", "then what they owe")
    crm.complete(open.first { $0.kind == .waiting }!.id)
    check(crm.lastContext("avi") == "Avi · lse econ student · applying to jane street", "then the hook")
    crm.rosterIDs = ["avi", "joaquin"]
    let digest = crm.digest(now: at(700))
    check(digest.hasPrefix("People:\n- Avi Shah (LSE). last talked"), "digest leads with who you talked to: \(digest.prefix(60))")
    check(digest.contains("Compared LoRA costs.") && digest.contains("Plays cricket"), "digest: summary and facts")
    check(digest.contains("Check in by") && !digest.contains("They promised"), "digest: open reminders only")
    check(digest.contains("- Joaquin Del Pego (UCSB). haven't talked yet"), "digest: the roster, even before a conversation")
    check(makeCRM(nil).digest().isEmpty, "nothing on record, no digest")
    let record = crm.record("avi")
    check(record.label == "lse econ student" && record.facts.contains("Plays cricket")
          && record.briefing.contains { $0.hasPrefix("Last talked") }, "the full record briefs the aid")
    crm.save(Encounter(summary: "Again.", at: at(3600), match: "avi"))
    check(crm.reminders.filter { $0.kind == .checkIn && $0.person == "avi" }.count == 1, "talking again moves the catch-up")
}

struct StubTools: Toolbox {
    let definitions = #"[{"type": "function", "function": {"name": "weather"}}]"#
    func working(_ name: String, arguments: String) -> String { "" }
    func run(_ name: String, arguments: String) async throws -> ToolResult { ToolResult(title: "", detail: "", icon: "") }
}

// Jarvis writes: find by name or pronoun, remember, follow up, save.
do {
    let crm = await MainActor.run { () -> CRM in
        let crm = makeCRM(nil)
        crm.rosterIDs = ["avi", "joaquin"]
        return crm
    }
    let tools = await MainActor.run { crm.jarvisTools(current: { "joaquin" }) }
    func tool(_ name: String) -> ExtraTool { tools.first { $0.name == name }! }
    await MainActor.run {
        check(crm.find("Avi", current: nil) == "avi" && crm.find("avi shah", current: nil) == "avi", "find by first or full name")
        check(crm.find("her", current: "joaquin") == "joaquin" && crm.find(nil, current: "joaquin") == "joaquin", "a pronoun is who you're talking to")
        check(crm.find("Priya", current: nil) == nil, "nobody by that name")
    }
    let saved = try? await tool("remember").run(#"{"person": "Avi", "fact": "Applying to Jane Street"}"#)
    let followed = try? await tool("follow_up").run(#"{"task": "Send Joaquin the deck", "days": 1}"#)
    let kept = try? await tool("save_contact").run(#"{"name": "Priya Raman"}"#)
    await MainActor.run {
        check(saved?.title == "Saved for Avi" && crm.facts(about: "avi").first?.text == "Applying to Jane Street", "remember writes a fact")
        check(followed?.title == "Send Joaquin the deck, tomorrow" && crm.open(for: "joaquin").contains { $0.kind == .todo }, "follow_up on whoever you're facing")
        check(kept?.title == "Priya Raman saved" && crm.saved.contains { $0.name == "Priya Raman" }, "save_contact adds them")
        let box = ExtraTools(base: StubTools(), extras: tools)
        check(box.definitions.contains("\"remember\"") && box.definitions.contains("\"weather\""), "the extras join the device tools")
    }
}

// 2. Consent: a stranger becomes a pending contact; a match on a pending id doesn't count.
await MainActor.run {
    let crm = makeCRM(nil)
    let priya = crm.save(Encounter(name: "Priya", label: "evals startup founder", facts: ["Runs an evals startup"],
                                   followups: [Recap.Followup(text: "Send Priya the deck")], summary: "Evals for agents.",
                                   hook: "asked about hiring", at: t0))
    check(priya?.hasPrefix("met-") == true && crm.consent(priya!) == .pending, "a stranger is a pending contact")
    check(!crm.open(for: priya!).contains { $0.kind == .checkIn }, "no catch-up clock until kept")
    check(crm.open(for: priya!).contains { $0.kind == .todo }, "but the promise is kept")
    let again = crm.save(Encounter(name: "Priya", summary: "Hiring.", at: at(3600), match: priya))
    check(again == priya && crm.contacts.count == 1, "the same name the same day is the same person, not a face match")
    check(crm.keywords(roster: ["Avi Shah"]) == ["Priya", "Avi", "Shah"], "speech keywords: met today first, then the roster")
    crm.keep(priya!)
    check(crm.consent(priya!) == .saved && crm.open(for: priya!).contains { $0.kind == .checkIn }, "kept: saved, with a catch-up")
    check(crm.save(Encounter(summary: "x", at: at(7200), match: priya)) == priya, "a saved contact may be matched")
    check(crm.lastContext(priya!) == "Priya · evals startup founder · you said: send Priya the deck", "lens line for a contact")
    crm.merge(priya!, into: "joaquin")
    check(crm.contacts.isEmpty && crm.facts(about: "joaquin").count == 1 && crm.open(for: "joaquin").contains { $0.kind == .todo },
          "merging moves everything onto the roster person")
    check(crm.save(Encounter(at: t0)) == nil, "a record with nobody and nothing in it is dropped")
}

// 3. Pending contacts expire; saved ones and the roster don't. Nothing transcript-like on disk.
let file = FileManager.default.temporaryDirectory.appendingPathComponent("crm-test-\(UUID()).json")
UserDefaults.standard.set(false, forKey: "keepMetFaces")   // the pending rule; the default keeps met people
await MainActor.run {
    let crm = makeCRM(nil, url: file)
    let stranger = crm.save(Encounter(name: "Sam", summary: "Met at the badge line.", at: t0))!
    let kept = crm.save(Encounter(name: "Rae", summary: "Robotics.", at: t0))!
    crm.keep(kept)
    crm.save(Encounter(summary: "Demo.", at: t0, match: "avi"))
    let later = makeCRM(nil, url: file, now: at(8 * 86400))
    check(later.consent(stranger) == nil && later.conversations(with: stranger).isEmpty, "unsaved people are gone after 7 days")
    check(later.consent(kept) == .saved && later.conversations(with: "avi").count == 1, "kept people and the roster stay")
    let disk = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    check(!disk.contains("\"lines\"") && !disk.contains("transcript"), "no transcript on disk")
}
UserDefaults.standard.removeObject(forKey: "keepMetFaces")
try? FileManager.default.removeItem(at: file)

// Met by face, the default: kept from the start, so recognition still works after a relaunch.
UserDefaults.standard.removeObject(forKey: "keepMetFaces")
await MainActor.run {
    let crm = makeCRM(nil, url: nil)
    let id = crm.meet(at: t0)
    check(crm.consent(id) == .saved && crm.name(id) == CRM.newName, "met by face: kept from the start by default")
}

// 4. The recorder: opens on the first line, attributed to the face in view, closes after two
// minutes of quiet, recap becomes the record.
var recap = Recap.Result()
recap.summary = "Compared LoRA costs."
recap.label = "lse econ student"
recap.facts = ["Applying to Jane Street"]
recap.followups = [Recap.Followup(text: "Send Avi the deck")]
let crm = await makeCRM(recap)
await MainActor.run {
    crm.facing("avi")
    crm.heard("So what are you working on?", speaker: "B", at: at(0))
    crm.heard("Glasses that recognise people.", speaker: "A", at: at(5))
    crm.heard("Lens, what's the weather", speaker: "A", at: at(8), command: true)
    crm.heard("Nice. I'm applying to Jane Street.", speaker: "B", at: at(10))
    check(crm.live?.faces == ["avi"] && crm.live?.lines.count == 3, "live, with Avi, commands left out")
    crm.tick(now: at(60))
    check(crm.live != nil, "a minute of quiet doesn't end it")
    crm.tick(now: at(130))
    check(crm.live == nil, "two minutes does")
}
await settle()
await MainActor.run {
    check(crm.conversations.first?.person == "avi" && crm.conversations.first?.place == "near Moscone, SF", "filed under Avi with a place")
    check(crm.open(for: "avi").contains { $0.text == "Send Avi the deck" }, "recap promises become reminders")
    crm.heard("hi", speaker: "B", at: at(9000))
    crm.tick(now: at(9001), force: true)
}
await settle()
await MainActor.run { check(crm.conversations.count == 1, "a hello in passing isn't a conversation") }

// Recap down: the coach's name and facts still make a record, unsummarized, retryable.
let offline = await makeCRM(nil)
await MainActor.run {
    offline.heardAboutThem = { ("Priya", ["Paralegal for two years"]) }
    offline.heard("I'm Priya.", speaker: "B", at: at(0))
    offline.heard("Toby.", speaker: "A", at: at(2))
    offline.heard("I was a paralegal for two years.", speaker: "B", at: at(4))
    offline.tick(now: at(5), force: true)
}
await settle()
await MainActor.run {
    let c = offline.conversations.first
    check(c?.recap == .failed && offline.name(c?.person ?? "") == "Priya", "failed recap: a record under Priya")
    check(offline.facts.first?.text == "Paralegal for two years", "with the coach's fact")
    check(c.map { offline.canRetry($0.id) } == true, "retryable while the transcript is in memory")
    offline.recapper = { _ in recap }
}
if let id = await MainActor.run(body: { offline.conversations.first?.id }) { await offline.retryRecap(id) }
await MainActor.run {
    check(offline.conversations.first?.summary == "Compared LoRA costs." && offline.conversations.count == 1, "retry fills it in")
    check(offline.contacts.count == 1, "retry doesn't make a second person")
}

// Meeting someone new by face: a pending contact at once, filled in mid-conversation by glances,
// and the conversation files under them with the name they gave.
check(Glance.parse("{\"name\": \"Priya Patel\", \"label\": \"evals startup founder\", \"facts\": [\"Building an evals startup\", null]}")
        == Glance(name: "Priya Patel", label: "evals startup founder", facts: ["Building an evals startup"]), "glance parse")
UserDefaults.standard.set(false, forKey: "keepMetFaces")
let meeting = await MainActor.run { () -> CRM in
    let crm = makeCRM(Recap.Result(summary: "Talked evals.", label: "evals startup founder", name: "Priya", facts: ["Building an evals startup"]))
    UserDefaults.standard.set(0, forKey: "glanceEvery")
    var glances: [String] = []
    crm.glancer = { input in
        glances.append(input.transcript.joined(separator: "|"))
        return Glance(name: "Priya", label: "evals startup founder", facts: ["Building an evals startup"])
    }
    let id = crm.meet(at: at(0))
    check(crm.consent(id) == .pending && crm.name(id) == CRM.newName, "met (switch off): pending, unnamed")
    crm.facing(id)
    crm.heard("Hi, I'm Toby.", speaker: "A", at: at(1))
    // The aid resolves a face-identified speaker to "p:<id>" before the CRM hears the line.
    crm.heard("Hey, I'm Priya, I'm building an evals startup.", speaker: "p:\(id)", at: at(2))
    crm.heard("Oh nice, what kind of evals?", speaker: "A", at: at(3))
    crm.heard("Agents, mostly. We just raised a seed.", speaker: "p:\(id)", at: at(4))
    return crm
}
await settle()
await MainActor.run {
    let id = meeting.newcomer ?? ""
    check(meeting.name(id) == "Priya", "the glance names them mid-conversation")
    check(meeting.facts(about: id).map(\.text) == ["Building an evals startup"], "facts kept as they come")
    check(meeting.label(id) == "evals startup founder", "label before any recap")
    meeting.named(id, "Pria")
    check(meeting.name(id) == "Pria" && meeting.renamable(id), "a heard name can be corrected")
    meeting.named(id, "Priya")
    meeting.rename(id, to: "Priya P.")
    check(!meeting.renamable(id), "a name the wearer typed is never overwritten")
    meeting.named(id, "Pria")
    check(meeting.name(id) == "Priya P.", "typed name kept")
    meeting.rename(id, to: "Priya")
    meeting.tick(now: at(5), force: true)
}
await settle()
await MainActor.run {
    let c = meeting.conversations.first
    check(meeting.contacts.count == 1 && c.map { meeting.name($0.person) } == "Priya", "filed under the face met, not a second Priya")
    check(meeting.facts.count == 1, "the recap's fact isn't repeated")
    var forgot: [String] = []
    meeting.onForgot = { forgot.append($0) }
    meeting.forgetPerson(c?.person ?? "")
    check(forgot == [c?.person ?? "-"], "forgetting tells the face store")
    UserDefaults.standard.removeObject(forKey: "glanceEvery")
}

// A conversation that changes what's true: the old fact goes, details go to the contact card.
await MainActor.run {
    var result = Recap.Result(summary: "Caught up.", facts: ["Works at Stripe now"])
    result.details = Recap.Details(work: "ML engineer at Stripe", email: "avi@x.com")
    result.outdated = ["works at ramp"]
    let crm = makeCRM(result)
    crm.learn("avi", "Works at Ramp", at: t0)
    crm.learn("avi", "Plays cricket", at: t0)
    var got: [(String, Recap.Details)] = []
    crm.onDetails = { got.append(($0, $1)) }
    var encounter = Encounter(at: at(60), match: "avi")
    encounter.apply(result)
    crm.save(encounter)
    let texts = crm.facts(about: "avi").map(\.text)
    check(!texts.contains("Works at Ramp") && texts.contains("Plays cricket") && texts.contains("Works at Stripe now"), "outdated fact retired, others kept")
    check(got.count == 1 && got.first?.0 == "avi" && got.first?.1.email == "avi@x.com", "details handed to the contact card")
    crm.save(Encounter(summary: "Again.", at: at(3600), match: "avi"))
    check(got.count == 1, "no details, no hand-off")
}

// Someone met by face who never speaks: nothing is filed. They stay as a contact (kept from the
// start, Oct 24) until removed in People.
do {
    let crm = CRM(url: nil)
    crm.glancer = { _ in Glance() }
    let id = crm.meet(at: at(0))
    crm.heard("Long day, huh.", speaker: "A", at: at(1))
    crm.heard("It really was.", speaker: "A", at: at(2))
    crm.tick(now: at(3), force: true)
    check(crm.conversations.isEmpty, "no conversation filed under a background face")
}

// The profile: who someone is overall. Revised only when a conversation shows something more
// central; a later niche fact neither replaces it nor jumps ahead of what matters on the card.
let profiled = Recap.parse("""
{"skip": false, "summary": "Talked evals.", "facts": ["Building an evals startup"],
 "profile": {"label": "evals startup founder", "about": "Building an evals startup after three years on Stripe's ML team.",
             "key": ["Building an evals startup", "Ex-Stripe ML engineer", "Invented fact"]}}
""")
check(profiled?.profile?.label == "evals startup founder" && profiled?.profile?.key.count == 3, "profile parsed")
check(Recap.parse("{\"skip\": false, \"summary\": \"Hi.\"}")?.profile == nil, "no profile key, no profile")
let profileFile = FileManager.default.temporaryDirectory.appendingPathComponent("crm-profile-\(UUID()).json")
do {
    let crm = makeCRM(nil, url: profileFile)
    crm.learn("avi", "Ex-Stripe ML engineer", at: t0)
    var first = Encounter(at: at(60), match: "avi")
    first.apply(profiled!)
    crm.save(first)
    check(crm.label("avi") == "evals startup founder", "profile label")
    check(crm.about("avi")?.hasPrefix("Building an evals startup") == true, "profile about")
    check(crm.facts(about: "avi").map(\.text).prefix(2) == ["Building an evals startup", "Ex-Stripe ML engineer"],
          "key facts lead, an invented key fact is dropped")

    // A second conversation about coffee: a niche fact, a narrow label for that chat, profile kept.
    let niche = Recap.parse("""
    {"skip": false, "summary": "Chatted about oat milk.", "label": "oat milk fan", "facts": ["Prefers oat milk"],
     "profile": {"label": null, "about": null, "key": ["Building an evals startup", "Ex-Stripe ML engineer", "Prefers oat milk"]}}
    """)!
    var second = Encounter(at: at(7200), match: "avi")
    second.apply(niche)
    crm.save(second)
    check(crm.label("avi") == "evals startup founder", "a narrow chat's label doesn't replace who they are")
    check(crm.about("avi")?.hasPrefix("Building an evals startup") == true, "null about keeps the big picture")
    check(crm.facts(about: "avi").first?.text == "Building an evals startup", "the newest niche fact doesn't lead")
    check(crm.record("avi").briefing.first?.hasPrefix("Who they are: Building") == true, "the aid is briefed with it first")
    check(crm.digest().contains("Building an evals startup after"), "Jarvis sees it")
    check(Recap.message(Recap.Input(wearer: "Toby", when: t0, with: "Avi", name: nil, picture: "evals startup founder",
                                    known: [], owed: [], transcript: [])).contains("Who they are: evals startup founder"),
          "the next recap starts from the current picture")

    // A big change does replace it.
    let moved = Recap.parse("""
    {"skip": false, "summary": "Avi joined Anthropic.", "facts": ["Joined Anthropic's evals team"], "outdated": ["Building an evals startup"],
     "profile": {"label": "anthropic evals researcher", "about": "Wound down his startup; now on Anthropic's evals team.",
                 "key": ["Joined Anthropic's evals team", "Ex-Stripe ML engineer"]}}
    """)!
    var third = Encounter(at: at(86400 * 30), match: "avi")
    third.apply(moved)
    crm.save(third)
    check(crm.label("avi") == "anthropic evals researcher" && crm.facts(about: "avi").first?.text == "Joined Anthropic's evals team",
          "a central change replaces the picture")
    check(CRM(url: profileFile).about("avi")?.hasPrefix("Wound down") == true, "profiles survive a relaunch")
}
try? FileManager.default.removeItem(at: profileFile)

// A glance's key facts order the card while someone new is still talking.
do {
    let crm = CRM(url: nil)
    UserDefaults.standard.set(0, forKey: "glanceEvery")
    var round = 0
    crm.glancer = { _ in
        round += 1
        return round == 1 ? Glance(facts: ["Founding an evals startup"], key: ["Founding an evals startup"])
            : Glance(facts: ["Has a golden retriever"], key: ["Founding an evals startup", "Has a golden retriever"])
    }
    let id = crm.meet(at: at(0))
    crm.facing(id)
    for (i, line) in ["I'm founding an evals startup.", "Yeah, it's going well.", "I have a golden retriever.", "His name is Toast."].enumerated() {
        crm.heard(line, speaker: "p:\(id)", at: at(Double(i + 1)))
        await Task.yield(); await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
    }
    check(crm.facts(about: id).first?.text == "Founding an evals startup", "glance key: the dog doesn't lead the card")
    UserDefaults.standard.removeObject(forKey: "glanceEvery")
}

print(failures == 0 ? "OK" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
