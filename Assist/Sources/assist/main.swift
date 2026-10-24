import AssistCore
import AssistSpeech
import Foundation

let usage = """
assist: the glasses conversation assistant, on the Mac, with a full event log.

  assist mic                     listen on the Mac microphone (Ctrl-C to stop)
  assist say "<text>" [--voice V] speak <text> with `say` and run it through the real pipeline
                                 (use [[slnc 600]] inside the text for a 600 ms pause)
  assist file <audio>            replay a recording in real time (--fast: as fast as possible)
  assist suite                   spoken scenarios with expected outcomes; exits 1 on failure
  assist text "<text>"           skip speech recognition; feed words at speaking pace

  -v        print every partial hypothesis, not just decisions
  --local   no network: only the on-device answers (math, time, date)

Logs: each run appends JSON lines to Assist/logs/<timestamp>.jsonl.
Key:  $ANSWER_API_KEY, else ANSWER_API_KEY in the repo's Secrets.xcconfig.
"""

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}
let verbose = flag("-v")
let offline = flag("--local")
let fast = flag("--fast")
let voice = option("--voice")
guard let mode = args.first else { print(usage); exit(2) }
let rest = Array(args.dropFirst())

// MARK: - Setup

/// Repo root: the first directory up from here that has project.yml.
let root: URL = {
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<6 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("project.yml").path) { return dir }
        dir.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}()

struct Offline: AnswerSource {
    func local(_ question: String) -> String? { Answerer.local(question) }
    func stream(_ question: String, context: String) -> AsyncThrowingStream<AnswerEvent, Error> {
        AsyncThrowingStream { $0.yield(.text("(offline)")); $0.finish() }
    }
}

let answerer = Answerer.fromEnvironment(searching: [root, URL(fileURLWithPath: FileManager.default.currentDirectoryPath)])
let source: AnswerSource = offline ? Offline() : answerer
let logDir = root.appendingPathComponent("Assist/logs")
let runStamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")

// MARK: - One run through the pipeline

@MainActor
func run(_ input: AudioInput?, text: String? = nil, label: String, echo: Bool = true) async -> [Turn] {
    let clock = SessionClock()
    let log = EventLog(path: logDir.appendingPathComponent("\(runStamp)-\(label).jsonl"),
                       verbose: verbose, echo: echo, now: { clock.now() })
    let engine = Engine(source: source, log: log, now: { clock.now() })
    if !offline, answerer.key == nil { log(.error, "no API key found; model answers will fail (try --local)") }
    log(.info, "model \(offline ? "offline" : answerer.provider.model) · \(label)")

    if let text {
        // No recognizer: emit growing hypotheses at ~3 words a second, then close the sentence.
        clock.zero = Date()
        for sentence in text.split(whereSeparator: { ".?!".contains($0) }).map({ $0.trimmed }) where !sentence.isEmpty {
            let mark = text[text.range(of: sentence)!.upperBound...].first.map(String.init) ?? ""
            var words: [String] = []
            for word in sentence.split(separator: " ") {
                words.append(String(word))
                try? await Task.sleep(for: .milliseconds(330))
                engine.heard(words.joined(separator: " "), final: false)
            }
            try? await Task.sleep(for: .milliseconds(450))
            engine.heard(words.joined(separator: " ") + mark, final: true, audioEnd: clock.now() - 0.45)
        }
    } else if let input {
        let transcriber = Transcriber()
        transcriber.status = { log(.info, $0) }
        let work = Task { @MainActor in
            try await transcriber.run(input, onStart: { clock.zero = Date() }) { text, final, end in
                engine.heard(text, final: final, audioEnd: end)
            }
        }
        if case .microphone = input {
            signal(SIGINT, SIG_IGN)
            let stop = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            stop.setEventHandler { work.cancel() }
            stop.resume()
            log(.info, "speak; Ctrl-C to stop")
            _ = await work.result
            stop.cancel()
        } else if case .failure(let error) = await work.result {
            log(.error, "\(error.localizedDescription)")
        }
    }

    // Let in-flight answers land.
    for _ in 0..<60 where engine.turns.contains(where: \.live) {
        try? await Task.sleep(for: .milliseconds(100))
    }
    return engine.turns.reversed()
}

func summarize(_ turns: [Turn]) {
    print("\n  #  heard → asked                                   result                                fires  1st tok   lead")
    for (i, turn) in turns.enumerated() {
        let result: String = switch turn.state {
        case .done, .answering: turn.answer
        case .personal: "SKIP (personal)"
        case .incomplete: "WAIT (incomplete)"
        case .abandoned: "dropped (not a question)"
        case .thinking: "(no answer)"
        case .failed(let e): "FAILED \(e)"
        }
        let tok = turn.firstTokenAfter.map { String(format: "%5.0fms", $0 * 1000) } ?? "     – "
        let lead = turn.lead.map { String(format: "%+6.2fs", $0) } ?? "     – "
        print(String(format: "%3d  %@  %@  %3d  %@  %@", i + 1,
                     turn.question.padding(toLength: 46, withPad: " ", startingAt: 0),
                     String(result.prefix(36)).padding(toLength: 36, withPad: " ", startingAt: 0),
                     turn.fires, tok, lead))
    }
    if turns.isEmpty { print("  (no questions)") }
    print("  lead = how long the answer was up before the speaker finished (negative: after)\n")
}

@MainActor
func speak(_ text: String, to url: URL) -> Bool {
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-o", url.path, "--data-format=LEI16@22050"] + (voice.map { ["-v", $0] } ?? []) + [text]
    do { try say.run(); say.waitUntilExit() } catch { return false }
    return say.terminationStatus == 0
}

// MARK: - Modes

struct Scenario {
    let speech: String
    /// nil: nothing should be shown. Otherwise the answer must contain one of these (case-insensitive).
    let expect: [String]?
    var note = ""
}

let scenarios: [Scenario] = [
    .init(speech: "How big is the sun?", expect: ["kilomet", "mile", "times", "diameter", "km"]),
    .init(speech: "So, um, how tall is the [[slnc 700]] Eiffel Tower?", expect: ["3"], note: "pause mid-question"),
    .init(speech: "Do you know what year the Berlin Wall fell?", expect: ["1989"]),
    .init(speech: "Who was the first person to [[slnc 600]] orbit the Earth?", expect: ["gagarin"], note: "pause mid-question"),
    .init(speech: "What's the capital of Australia?", expect: ["canberra"]),
    .init(speech: "I was in Berlin last summer. How far is it from Munich?", expect: ["km", "kilomet", "mile"]),
    .init(speech: "What is 17 times 23?", expect: ["391"]),
    .init(speech: "How was your flight?", expect: nil),
    .init(speech: "Should we grab lunch after this?", expect: nil),
    .init(speech: "Did you see the keynote this morning?", expect: nil),
    .init(speech: "The demo went really well, I think.", expect: nil),
]

switch mode {
case "mic":
    summarize(await run(.microphone, label: "mic"))

case "file":
    guard let path = rest.first else { print(usage); exit(2) }
    summarize(await run(.file(URL(fileURLWithPath: path), realTime: !fast), label: "file"))

case "say":
    guard let text = rest.first else { print(usage); exit(2) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("assist-say.wav")
    guard speak(text, to: url) else { print("say failed"); exit(1) }
    summarize(await run(.file(url, realTime: true), label: "say"))

case "text":
    guard let text = rest.first else { print(usage); exit(2) }
    summarize(await run(nil, text: text, label: "text"))

case "suite":
    var failures = 0
    for (n, scenario) in scenarios.enumerated() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("assist-suite-\(n).wav")
        guard speak(scenario.speech, to: url) else { print("say failed"); exit(1) }
        let turns = await run(.file(url, realTime: true), label: "suite-\(n + 1)", echo: verbose)
        let shown = turns.filter { [.done, .answering].contains($0.state) }
        var problems: [String] = []
        if let expect = scenario.expect {
            if shown.isEmpty { problems.append("no answer shown") }
            else if !shown.contains(where: { t in expect.contains { t.answer.lowercased().contains($0) } }) {
                problems.append("answer \"\(shown.map(\.answer).joined(separator: " | "))\" lacks \(expect)")
            }
            let asked = max(1, scenario.speech.filter { $0 == "?" }.count)
            let questions = turns.filter { $0.state != .abandoned }
            if questions.count > asked {
                problems.append("split into \(turns.count) questions: \(turns.map { "\"\($0.question)\"" }.joined(separator: ", "))")
            }
        } else if !shown.isEmpty {
            problems.append("showed \"\(shown[0].answer)\" for a non-factual sentence")
        }
        let spoken = scenario.speech.replacingOccurrences(of: #"\[\[slnc (\d+)\]\]"#, with: "‹pause $1ms›", options: .regularExpression)
        let lead = shown.first?.lead.map { String(format: "lead %+.2fs", $0) } ?? ""
        let tok = shown.first?.firstTokenAfter.map { String(format: "1st token %.0fms", $0 * 1000) } ?? ""
        if problems.isEmpty {
            print("PASS  \(spoken)\n      → \(shown.first?.answer ?? "(nothing shown)")   \(tok)  \(lead)")
        } else {
            failures += 1
            print("FAIL  \(spoken)\n      → \(problems.joined(separator: "; "))")
            for t in turns { print("        turn: heard \"\(t.heard)\" asked \"\(t.question)\" → \(t.state) \"\(t.answer)\" fires=\(t.fires)") }
        }
    }
    print("\n\(scenarios.count - failures)/\(scenarios.count) scenarios passed · logs in \(logDir.path)")
    exit(failures == 0 ? 0 : 1)

default:
    print(usage)
    exit(2)
}
