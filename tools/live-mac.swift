import AVFoundation
import Foundation

// The conversation aid, live on a Mac: the phone's Listener and Aid, unchanged, with the lens drawn
// in the terminal. Muse transcribes (with who-said-what), Groq answers and coaches.
//
//   sh tools/live-mac.sh                 talk to it (mic)
//   sh tools/live-mac.sh --file x.wav    replay a recording at real time (never played aloud)
//
// While it runs: type m + Enter if the last line was you, q + Enter to stop.

var arguments = Array(CommandLine.arguments.dropFirst())
var file: URL?
if let i = arguments.firstIndex(of: "--file"), i + 1 < arguments.count {
    file = URL(fileURLWithPath: arguments[i + 1])
    arguments.removeSubrange(i...(i + 1))
}
let seconds = Double(arguments.first ?? "") ?? 1800
let t0 = Date()

// MARK: - Terminal

enum Style {
    static let dim = "\u{1B}[2m", bold = "\u{1B}[1m", reset = "\u{1B}[0m"
    static let me = "\u{1B}[32m", them = "\u{1B}[36m", aid = "\u{1B}[33m", warn = "\u{1B}[31m"
}

func stamp(_ date: Date = Date()) -> String { String(format: "%6.1f", date.timeIntervalSince(t0)) }
func clearLine() { print("\r\u{1B}[2K", terminator: "") }
func out(_ s: String) { clearLine(); print(s); fflush(stdout) }
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

/// Words wrapped to `width` columns.
func wrap(_ text: String, _ width: Int) -> [String] {
    var lines: [String] = [], current = ""
    for word in text.split(separator: " ") {
        if current.isEmpty { current = String(word) }
        else if current.count + 1 + word.count <= width { current += " " + word }
        else { lines.append(current); current = String(word) }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
}

/// The lens, as a box. Same three parts the glasses render: header, passing card, pinned follow-up.
func drawLens(_ view: LensView) {
    let width = 54
    var rows: [String] = []
    if let header = view.header { rows.append(Style.dim + header.uppercased() + Style.reset) }
    if let card = view.card {
        let mark = card.kind == .answer ? "A" : card.kind == .definition ? "i" : "?"
        let title = card.title + (card.live && card.title != "\u{2026}" ? " \u{2026}" : "")
        for (i, line) in wrap(title, width - 4).enumerated() { rows.append((i == 0 ? "\(mark)  " : "   ") + Style.bold + line + Style.reset) }
        for line in wrap(card.detail, width - 4) { rows.append("   " + Style.dim + line + Style.reset) }
    }
    if let followup = view.followup {
        if view.card != nil || view.header != nil { rows.append(Style.dim + String(repeating: "\u{2500}", count: 6) + Style.reset) }
        for (i, line) in wrap(followup, width - 4).enumerated() { rows.append((i == 0 ? "\u{21B3}  " : "   ") + line) }
    }
    if rows.isEmpty { rows = [Style.dim + "(clear)" + Style.reset] }
    let visible: (String) -> Int = { $0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).count }
    var text = "        \u{250C}\u{2500} lens " + String(repeating: "\u{2500}", count: width - 6) + "\u{2510}\n"
    for row in rows { text += "        \u{2502} " + row + String(repeating: " ", count: max(0, width - 1 - visible(row))) + "\u{2502}\n" }
    text += "        \u{2514}" + String(repeating: "\u{2500}", count: width) + "\u{2518}"
    out(text)
}

// MARK: - Wiring

@MainActor final class Session {
    let listener = Listener()
    let aid: Aid
    var lensDraw: Task<Void, Never>?
    var drawn = LensView()

    init() {
        let me = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "App/people.json"))) as? [[String: Any]])?
            .first { $0["isMe"] as? Bool == true }
        let wearer = (me?["name"] as? String)?.split(separator: " ").first.map(String.init) ?? "the wearer"
        aid = Aid(config: .fromBundle(wearer: wearer))
        listener.keywords = [wearer]
        listener.file = file

        listener.onPartial = { [weak self] text in
            self?.aid.heard(partial: text)
            clearLine()
            print("\(stamp())  \(Style.dim)\u{2026}     \(String(text.suffix(100)))\(Style.reset)", terminator: "")
            fflush(stdout)
        }
        listener.onLine = { [weak self] text, speaker, level in
            self?.aid.heard(line: text, speaker: speaker, level: level)
        }
        listener.onFileEnd = { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))   // let the last coach call land
                self?.finish()
            }
        }
        aid.onEvent = { [weak self] event in self?.show(event) }
        aid.onLens = { [weak self] view in self?.lensChanged(view) }
    }

    func start() async {
        let config = aid.config
        func lane(_ model: Aid.Model?) -> String { model.map { "\($0.provider.rawValue) \($0.model)" } ?? "off" }
        out("\(Style.bold)Conversation aid\(Style.reset)  speech: Muse (who-said-what) · answers: \(lane(config.answers))"
            + " · coach: \(lane(config.coach)) · backup: \(lane(config.backup)) · research: \(config.researcher?.name ?? "off")")
        out(file == nil ? "Talk normally. Type m + Enter if the last line was you, q + Enter to stop."
                        : "Replaying \(file!.lastPathComponent) at real time (not played aloud).")
        await listener.start()
        if !listener.listening { out(Style.warn + listener.status + Style.reset); exit(1) }
        Task {
            var said = ""
            var loudest: Float = 0
            let started = Date()
            var warned = false
            while true {
                try? await Task.sleep(for: .milliseconds(200))
                loudest = max(loudest, listener.level)
                if listener.status != said {
                    said = listener.status
                    out("\(stamp())  \(Style.dim)\(said == "Listening" ? "connected — go ahead" : said)\(Style.reset)")
                }
                // A mic without permission delivers digital silence, which looks like nobody talking.
                if file == nil, !warned, Date().timeIntervalSince(started) > 5, loudest == 0 {
                    warned = true
                    out("\(stamp())  \(Style.warn)no sound is reaching the tool: allow your terminal in System Settings → "
                        + "Privacy & Security → Microphone, then rerun\(Style.reset)")
                }
            }
        }
    }

    func show(_ event: Event) {
        let s = stamp(event.at)
        let dim = { (text: String) in text.isEmpty ? "" : "  \(Style.dim)\(text)\(Style.reset)" }
        switch event.kind {
        case .line:
            let tag = aid.tag(event.speaker)
            let color = tag == "ME" ? Style.me : tag == "THEM" ? Style.them : ""
            out("\(s)  \(color)\(pad(tag, 5)) \(event.text)\(Style.reset)" + dim(event.detail))
        case .answer: out("\(s)  \(Style.aid)  answer   \(event.text)\(Style.reset)" + dim(event.detail))
        case .define: out("\(s)  \(Style.aid)  define   \(event.text)\(Style.reset)" + dim("— " + event.detail))
        case .followup: out("\(s)  \(Style.aid)  ask      \(event.text == "used" ? "used: " + event.detail : event.text)\(Style.reset)")
        case .research: out("\(s)  \(Style.aid)  found    \(event.text)\(Style.reset)" + dim(event.detail))
        case .lookup: out("\(s)  \(Style.aid)  lookup   \(event.text)\(Style.reset)" + dim(event.detail))
        case .learned: out("\(s)  \(Style.aid)  learned  \(event.text)\(Style.reset)")
        case .roles: out("\(s)  \(Style.aid)  roles    \(event.text)\(Style.reset)" + dim(event.detail))
        case .status: out("\(s)  \(Style.warn)  status   \(event.text)\(Style.reset)")
        }
    }

    /// Answers stream token by token; redraw the box once things settle, not on every token.
    func lensChanged(_ view: LensView) {
        lensDraw?.cancel()
        lensDraw = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(view.card?.live == true ? 600 : 150))
            guard !Task.isCancelled, let self, self.aid.lens != self.drawn else { return }
            self.drawn = self.aid.lens
            drawLens(self.aid.lens)
        }
    }

    func finish() {
        listener.stop()
        func median(_ xs: [Int]?) -> String {
            guard let xs, !xs.isEmpty else { return "—" }
            return "\(xs.sorted()[xs.count / 2]) ms"
        }
        let events = aid.events
        let count: (Event.Kind) -> Int = { kind in events.filter { $0.kind == kind }.count }
        let followups = events.filter { $0.kind == .followup && $0.text != "used" && $0.text != "cleared" }.count
        out("")
        out("\(Style.bold)Summary\(Style.reset)  \(aid.lines.count) lines · \(count(.answer)) answers · \(count(.define)) definitions · "
            + "\(followups) follow-ups · \(count(.research)) lookups (\(count(.lookup)) asked for)")
        out("         answer first word median \(median(aid.timings["answer"])) · coach call median \(median(aid.timings["coach"]))"
            + (aid.timings["research"] == nil ? "" : " · research median \(median(aid.timings["research"]))"))
        if let header = aid.them.header {
            out("         them: \(header)" + (aid.them.facts.isEmpty ? "" : "; " + aid.them.facts.joined(separator: "; ")))
        }
        exit(0)
    }
}

// MARK: - Main

// Without this, macOS can throttle a terminal process in the background, and a stalled mic looks
// like "Ingress audio slower than real-time" to the Muse server.
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "live mic")

let session = MainActor.assumeIsolated { Session() }

signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler { MainActor.assumeIsolated { session.finish() } }
interrupt.resume()

// m = the last line was me, q = stop.
Thread.detachNewThread {
    while let line = readLine() {
        let command = line.trimmingCharacters(in: .whitespaces).lowercased()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if command == "m" { session.aid.lastLineWasMe() }
                if command == "q" { session.finish() }
            }
        }
    }
}

Task { @MainActor in
    await session.start()
    try? await Task.sleep(for: .seconds(seconds))
    session.finish()
}
RunLoop.main.run()
