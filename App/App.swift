import PhotosUI
import SwiftUI

@main
struct CalHacksApp: App {
    @State private var store = Store()
    @State private var glasses = Glasses()
    @State private var assistant = Assistant()
    @State private var crm = CRM()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Glasses.configure()
        // Before anything reads a threshold: a pushed tuning.json is authoritative from launch.
        Tuning.shared.start()
        DispatchQueue.global(qos: .userInitiated).async { FaceEngine.warmUp() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(glasses)
                .environment(assistant)
                .environment(crm)
                .onOpenURL { glasses.handle($0) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await assistant.ensureListening() } }
                }
                .task {
                    glasses.store = store
                    assistant.glasses = glasses
                    assistant.store = store
                    assistant.crm = crm
                    // Preview data is made up: it schedules no real notifications.
                    if ProcessInfo.processInfo.environment["PREVIEW_CRM"] != "1" {
                        crm.onScheduled = { reminder in
                            Nudges.schedule(reminder, title: crm.name(reminder.person))
                        }
                    }
                    crm.onCancelled = { Nudges.cancel($0) }
                    crm.onSaved = { kept in store.saved = kept.map { crm.person($0) } }
                    // Listening is on from launch; the mic pill turns it off.
                    Task { await assistant.ensureListening() }
                    // Knobs that are read once rather than per use have to be re-applied by hand
                    // when a push lands; Store re-reads the roster on the same notification.
                    NotificationCenter.default.addObserver(forName: Tuning.changed, object: nil, queue: .main) { _ in
                        let wanted = Tuning.bool("AutoIdentify", glasses.watching)
                        if wanted != glasses.watching { glasses.watching = wanted }
                        // Resolution and frame rate are fixed when the camera is added, so a push
                        // needs a fresh camera to mean anything. Makes streamRes a 0.3 s change.
                        glasses.restreamIfSettingsChanged()
                    }
                    // First names spelled right in the transcript, e.g. "Joaquin" not "Wakeen".
                    // Plus anyone met today or kept (the CRM); refreshed on every arm.
                    assistant.listener.keywords = crm.keywords(roster: store.people.map(\.name))
                    #if DEBUG
                    let env = ProcessInfo.processInfo.environment
                    if Glasses.prefersMock {
                        await glasses.useMockGlasses()
                        Task { await glasses.connect() }
                    } else {
                        await glasses.dropMock()
                    }
                    // PREVIEW_SEEN="joaquin:7200,mirabelle:900" = seen that many seconds ago.
                    for entry in (ProcessInfo.processInfo.environment["PREVIEW_SEEN"] ?? "").split(separator: ",") {
                        let parts = entry.split(separator: ":")
                        if parts.count == 2, let seconds = Double(parts[1]) {
                            store.markSeen(String(parts[0]), at: .now.addingTimeInterval(-seconds))
                        }
                    }
                    // PREVIEW_POV=<image path>: a still standing in for the camera, at its own pixel
                    // size, so the lens overlay can be checked in the Simulator, which has no camera.
                    if let path = env["PREVIEW_POV"], let still = UIImage(contentsOfFile: path) {
                        glasses.pov = still
                        glasses.frameSize = CGSize(width: still.size.width * still.scale, height: still.size.height * still.scale)
                    }
                    // REPLAY_RUN=<folder in Documents/frames> plays a recorded run through the matcher.
                    if let name = env["REPLAY_RUN"],
                       let run = FrameRun.load(FrameRecorder.root.appendingPathComponent(name)) {
                        glasses.replay(run)
                        return
                    }
                    // PREVIEW_CRM=1: two made-up people with notes, kept, to see People filled in.
                    if env["PREVIEW_CRM"] == "1", crm.conversations.isEmpty {
                        let maya = crm.save(Encounter(
                            name: "Maya Chen", label: "evals startup founder",
                            facts: ["Closed a seed round led by Lux", "Brother went to UCSB"],
                            followups: [.init(text: "Intro Maya to an eval engineer", mine: true, dueInDays: 2)],
                            summary: "Calibrating LLM judges is her hardest problem; hiring two eval engineers.",
                            hook: "asked about hiring", topics: ["LLM judges", "hiring", "UCSB"],
                            at: .now.addingTimeInterval(-3 * 3600), ended: .now.addingTimeInterval(-3 * 3600 + 540),
                            place: "near Sproul Plaza, Berkeley"))
                        let dana = crm.save(Encounter(
                            name: "Dana Ruiz", label: "ICU nurse at UCSF",
                            facts: ["Back from her sister's wedding in Lisbon"],
                            followups: [.init(text: "Send Dana the demo video", mine: true, dueInDays: 1)],
                            summary: "Caught up on Lisbon; the ICU is short-staffed.",
                            hook: "owe her the demo video", topics: ["Lisbon", "work"],
                            at: .now.addingTimeInterval(-26 * 3600), ended: .now.addingTimeInterval(-26 * 3600 + 720)))
                        for id in [maya, dana].compactMap(\.self) { crm.keep(id) }
                    }
                    if let id = ProcessInfo.processInfo.environment["PREVIEW_PERSON"],
                       let person = store.people.first(where: { $0.id == id }) {
                        glasses.preview(person)
                        if env["PREVIEW_CONFIRM"] == "1" { await glasses.lensIdentify(source: "preview") }
                        // PREVIEW_AID="title|detail|follow-up": an aid card with the mic on, to see
                        // the bio hand the lens to the aid after `bioHolds`.
                        if let spec = env["PREVIEW_AID"] {
                            let parts = spec.components(separatedBy: "|")
                            glasses.aidArmed = true
                            // PREVIEW_WORK="Researching the GENIUS Act": a thinking row with its countdown.
                            let work = env["PREVIEW_WORK"].map { [Work(id: 99, label: $0, started: Date())] } ?? []
                            glasses.showAid(LensView(card: Card(kind: .answer, title: parts[0],
                                                                detail: parts.count > 1 ? parts[1] : ""),
                                                     followup: parts.count > 2 ? parts[2] : nil, working: work))
                        }
                        // PREVIEW_GROUP="joaquin,avi*,me": a conversation of several, * = talking,
                        // me = the wearer has the floor.
                        if let spec = env["PREVIEW_GROUP"] {
                            glasses.aidArmed = true
                            let ids = spec.split(separator: ",").map(String.init)
                            let members = ids.filter { $0 != "me" }.compactMap { raw -> Member? in
                                let id = raw.replacingOccurrences(of: "*", with: "")
                                guard let p = store.people.first(where: { $0.id == id }) else { return nil }
                                return Member(id: id, name: String(p.name.split(separator: " ").first ?? ""),
                                              headline: p.headline, speaking: raw.hasSuffix("*"))
                            }
                            assistant.pinnedGroup = (members, ids.contains("me"))
                            glasses.setGroup(members, meSpeaking: ids.contains("me"))
                        }
                        return
                    }
                    #endif
                    await glasses.connectIfRegistered()
                }
        }
    }
}

struct HomeView: View {
    @Environment(Store.self) private var store
    @Environment(Glasses.self) private var glasses
    @Environment(Assistant.self) private var assistant

    @State private var query = ""
    @State private var path = NavigationPath()

    /// One flat list so a person moving between sections animates as a move, not a delete + insert.
    private enum Item: Identifiable {
        case section(String)
        case current(Person)
        case row(Person)

        var id: String {
            switch self {
            case .section(let title): "section-\(title)"
            case .current(let person), .row(let person): person.id
            }
        }
    }

    private func items(now: Date) -> [Item] {
        let people = store.recents
        if !query.isEmpty {
            let q = query.lowercased()
            return people.filter { person in
                ([person.name, person.role] + (person.tags ?? [])).contains { $0.lowercased().contains(q) }
            }.map(Item.row)
        }
        var items: [Item] = []
        var rest = people
        if let first = rest.first, isCurrent(first, now: now) {
            items.append(.current(first))
            rest.removeFirst()
        }
        let met = rest.filter { store.lastSeen[$0.id] != nil }
        let unmet = rest.filter { store.lastSeen[$0.id] == nil }
        if !met.isEmpty { items.append(.section("Recent")); items += met.map(Item.row) }
        if !unmet.isEmpty { items.append(.section("Not met yet")); items += unmet.map(Item.row) }
        return items
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                #if DEBUG
                // Only takes space when there is something to mirror: an unconditional
                // 300pt panel above the header blacked out the app on device.
                LiveLensPanel()
                #endif
                HomeHeader()
                // Live frame size and rate off the glasses, plus recording.
                StreamControls()
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("People")
                            .font(.system(size: 34, weight: .semibold, design: .serif))
                            .padding(.horizontal, 20)
                            .padding(.top, 10)
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.top, 2)
                            .padding(.bottom, 14)
                        SearchField(text: $query)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)
                        // Every slot from here to the person card is a fixed size, present or not, so
                        // the chat and the card never jump when a line appears, wraps or goes away.
                        notice
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 10)
                        HeardLine.template.hidden()
                            .overlay(alignment: .topLeading) { if assistant.armed { HeardLine() } }
                            .clipped()
                            .padding(.horizontal, 20)
                            .padding(.bottom, 10)
                        AidStrip.template.hidden()
                            .overlay(alignment: .topLeading) {
                                if assistant.armed, !assistant.aid.lens.isEmpty {
                                    AidStrip(view: assistant.aid.lens)
                                }
                            }
                            .clipped()
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color(.separator)))
                            .padding(.horizontal, 16)
                            .padding(.bottom, 10)
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            VStack(spacing: 0) {
                                if query.isEmpty { FollowUps(now: context.date) }
                                ForEach(items(now: context.date)) { item in
                                    switch item {
                                    case .section(let title):
                                        SectionLabel(title)
                                            .padding(.horizontal, 20)
                                            .padding(.top, 18)
                                            .padding(.bottom, 2)
                                    case .current(let person):
                                        CurrentCard(person: person)
                                            .padding(.horizontal, 16)
                                            .padding(.bottom, 4)
                                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                                    case .row(let person):
                                        ContactRow(person: person, seen: store.lastSeen[person.id], now: context.date)
                                    }
                                }
                            }
                        }
                        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: store.recents.map(\.id))
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.immediately)
                actionButton
            }
            .background(Color(.systemBackground))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Person.self) { PersonView(person: $0) }
            #if DEBUG
            .onAppear {
                if let id = ProcessInfo.processInfo.environment["PREVIEW_OPEN"],
                   let person = store.people.first(where: { $0.id == id }) { path.append(person) }
            }
            #endif
        }
    }

    private var summary: String {
        let count = store.contacts.count
        let today = store.metToday
        return "\(count) \(count == 1 ? "person" : "people") · \(today == 0 ? "none" : "\(today)") met today"
    }

    /// The person you just identified stays featured for 15 minutes.
    private func isCurrent(_ person: Person, now: Date) -> Bool {
        guard let seen = store.lastSeen[person.id] else { return false }
        return now.timeIntervalSince(seen) < 15 * 60
    }

    /// One quiet line under the title: what's happening right now, if anything.
    @ViewBuilder private var notice: some View {
        if glasses.identifying {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Recognizing")
            }
            .font(.subheadline).foregroundStyle(.secondary)
        } else if glasses.watching, glasses.connected, case .ready = glasses.result, store.hasFaces {
            Text("Watching for faces").font(.subheadline).foregroundStyle(.secondary)
        } else if case .noFace = glasses.result {
            Text("No one in view. Face them and try again.").font(.subheadline).foregroundStyle(.secondary)
        } else if !store.hasFaces {
            Text("Add photos so people can be recognized.").font(.subheadline).foregroundStyle(.secondary)
        } else if store.lastSeen.isEmpty {
            Text(glasses.watching ? "Look at someone — their card appears by itself."
                                   : "Look at someone and press the button on your glasses.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var actionButton: some View {
        VStack(spacing: 10) {
            // Recognition is automatic, so once connected there is nothing to press.
            if !glasses.connected {
                Button {
                    Task { await glasses.connect() }
                } label: {
                    Text(buttonTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Color.primary, in: Capsule())
                }
                .disabled(glasses.connecting)
            }
            if !glasses.connected, glasses.status != "Not connected" {
                Text(glasses.status).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var buttonTitle: String {
        if glasses.connecting { return "Connecting" }
        return "Connect glasses"
    }
}

/// The question just heard and the answer that went to the lens.
/// Proof of life for the mic: which microphone, how loud, and the last thing it heard.
struct HeardLine: View {
    @Environment(Assistant.self) private var assistant

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "waveform").font(.caption).foregroundStyle(.red)
                    .opacity(0.35 + 0.65 * Double(assistant.level))
                Text(assistant.listener.input.isEmpty ? assistant.status : assistant.listener.input)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if assistant.listener.status != "Listening" {
                    Text("· \(assistant.listener.status)").font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
            }
            if !assistant.members.isEmpty || assistant.voiceID != nil {
                GroupLine()
            }
            if let heard = assistant.heard {
                (Text(heard.tag + "  ").font(.caption2.weight(.bold)).foregroundColor(.secondary)
                 + Text(heard.text).font(.subheadline))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The tallest the line gets — status, a group row, two lines heard — so its slot is that size
    /// whatever it is showing, and nothing under it moves.
    static var template: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Listening").font(.caption)
            Text("Group").font(.caption).padding(.vertical, 3)
            Text("Heard\nHeard").font(.subheadline).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Who's in the conversation and who has the floor, plus whether the glasses' own mic is helping
/// tell the wearer apart. The lens shows the same group once there are two or more.
struct GroupLine: View {
    @Environment(Assistant.self) private var assistant

    var body: some View {
        HStack(spacing: 10) {
            if assistant.meSpeaking { chip("You", speaking: true) }
            ForEach(assistant.members, id: \.id) { chip($0.name, speaking: $0.speaking) }
            Spacer(minLength: 4)
            if let voice = assistant.voiceID {
                Label(voice.label, systemImage: "person.wave.2")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(voice.working ? Color.green : .secondary)
                    .lineLimit(1)
            }
        }
    }

    private func chip(_ name: String, speaking: Bool) -> some View {
        HStack(spacing: 4) {
            if speaking { Image(systemName: "waveform").font(.caption2) }
            Text(name).font(.caption.weight(speaking ? .semibold : .regular))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(speaking ? Color.accentColor.opacity(0.18) : Color(.secondarySystemFill)))
    }
}

/// Slow work in flight: a ring that drains over the estimate, the seconds left, and a pulse once
/// it runs past ("almost there").
struct WorkRow: View {
    let work: Work

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { context in
            let elapsed = context.date.timeIntervalSince(work.started)
            let left = max(0, 1 - elapsed / work.eta)
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(Color(.systemFill), lineWidth: 2.5)
                    Circle().trim(from: 0, to: left)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 16, height: 16)
                .opacity(left > 0 ? 1 : 0.4 + 0.6 * abs(sin(elapsed * 3)))
                Text(work.label).font(.footnote)
                Spacer(minLength: 4)
                Text(work.remaining(at: context.date).map { "\($0)s" } ?? "almost there")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

/// What the conversation aid has on the lens right now, on the phone.
struct AidStrip: View {
    let view: LensView

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let card = view.card {
                Text(card.title)
                    .font(.system(.body, design: .serif, weight: .medium))
                    .lineLimit(1)
                if !card.detail.isEmpty {
                    Text(card.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            // One last row: work in flight wins over the follow-up, so the strip is three lines.
            if let work = view.working.first {
                WorkRow(work: work)
            } else if let followup = view.followup {
                Label(followup, systemImage: "bubble.left").font(.footnote).lineLimit(1)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A full strip — title, detail, a work or follow-up row — so its slot is always that size and
    /// the person card under it stays put. The outline is the slot's.
    static var template: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Title").font(.system(.body, design: .serif, weight: .medium))
            Text("Detail").font(.footnote)
            Label("Follow-up", systemImage: "bubble.left").font(.footnote).frame(minHeight: 16)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The person you're talking to now: photo, who they are, and how you know them.
struct CurrentCard: View {
    @Environment(Store.self) private var store
    @Environment(Glasses.self) private var glasses
    let person: Person

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: person) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        Avatar(person: person, size: 60)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Circle().fill(Color.green).frame(width: 6, height: 6)
                                Text("TALKING NOW").font(.caption2.weight(.bold)).tracking(1).foregroundStyle(.green)
                            }
                            Text(person.name).font(.system(.title2, design: .serif, weight: .semibold))
                            Text(person.role).font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    if let tags = person.tags, !tags.isEmpty { TagRow(tags: tags) }
                }
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            if case .known(let match, let face?) = glasses.result, match.person.id == person.id {
                SaveFaceMenu(face: face, label: "Not \(person.name.split(separator: " ").first ?? "them")?")
                    .font(.footnote)
                    .tint(.secondary)
                    .padding(.top, 14)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct ContactRow: View {
    @Environment(Store.self) private var store
    @Environment(CRM.self) private var crm
    let person: Person
    let seen: Date?
    let now: Date

    var body: some View {
        NavigationLink(value: person) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Avatar(person: person, size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name).font(.body.weight(.medium))
                        Text(subtitle)
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let seen {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(relative(seen, now: now)).font(.footnote).foregroundStyle(.secondary)
                            let count = store.encounters[person.id]?.count ?? 0
                            if count > 1 { Text("\(count)×").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }
                        }
                    }
                }
                .padding(.vertical, 11)
                Divider().padding(.leading, 60)
            }
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension ContactRow {
    /// What you talked about last, once there's a conversation; until then who they are.
    private var subtitle: String {
        if let topics = crm.conversations(with: person.id).first?.topics, !topics.isEmpty {
            return "Talked about " + topics.prefix(2).joined(separator: ", ")
        }
        if let label = crm.label(person.id) { return label }
        return person.tags?.prefix(2).joined(separator: " · ") ?? person.role
    }
}

/// "Today, 8:22 PM", "Yesterday, 6:10 PM", then "Wed, Oct 21, 6:10 PM".
func dayAndTime(_ date: Date) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today, \(time)" }
    if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
    return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + ", " + time
}

func relative(_ date: Date, now: Date = .now) -> String {
    if now.timeIntervalSince(date) < 60 { return "Just now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: now)
}

struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TagRow: View {
    let tags: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
        }
    }
}

struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search people, schools, companies", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Saves the identified face as a sample for someone, then re-matches.
struct SaveFaceMenu: View {
    @Environment(Store.self) private var store
    @Environment(Glasses.self) private var glasses
    let face: FaceHit
    let label: String

    var body: some View {
        Menu(label) {
            ForEach(store.people) { person in
                Button(person.name) {
                    store.enroll(person.id, face)
                    glasses.rematch()
                }
            }
        }
    }
}

struct Avatar: View {
    @Environment(Store.self) private var store
    let person: Person
    var size: CGFloat = 44
    /// nil = circle.
    var corner: CGFloat? = nil

    var body: some View {
        Group {
            if let image = store.avatars[person.id] {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(person.name.prefix(1)).font(.system(size: size * 0.4, weight: .semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemFill))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner ?? size / 2, style: .continuous))
    }
}

/// A contact's record: who they are, how often you've met, your notes, and every encounter.
struct PersonView: View {
    @Environment(Store.self) private var store
    @Environment(CRM.self) private var crm
    let person: Person
    @State private var note = ""
    @FocusState private var editingNote: Bool

    private var encounters: [Date] { store.encounters[person.id] ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                stats.padding(.top, 22)
                PersonCRM(person: person)
                section("Details") { details }
                section("Notes") { notes }
                section("Activity") { activity }
                // Consent: someone met but not kept can't be recognized, so no face photos.
                if crm.consent(person.id) != .pending { section("Recognition") { recognition } }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { note = store.notes[person.id] ?? "" }
        .onChange(of: note) { _, text in store.setNote(person.id, text) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Avatar(person: person, size: 84, corner: 22)
                .padding(.bottom, 16)
            Text(person.name).font(.system(size: 30, weight: .semibold, design: .serif))
            Text(person.role).font(.callout).foregroundStyle(.secondary).padding(.top, 3)
            if let tags = person.tags, !tags.isEmpty { TagRow(tags: tags).padding(.top, 12) }
        }
        .padding(.top, 8)
    }

    /// Three numbers that answer "how well do I know them".
    private var stats: some View {
        HStack(spacing: 0) {
            stat(encounters.isEmpty ? "None" : "\(encounters.count)×", "Met")
            Divider().frame(height: 34)
            stat(store.lastSeen[person.id].map { relative($0) } ?? "Never", "Last seen")
            Divider().frame(height: 34)
            stat(encounters.first.map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? "Not yet", "First met")
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(.callout, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            Text(label.uppercased()).font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
            content()
        }
        .padding(.top, 28)
    }

    @ViewBuilder private var details: some View {
        if person.details.isEmpty {
            Text("No details yet.").font(.subheadline).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(person.details, id: \.text) { detail in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(label(detail.kind)).font(.subheadline).foregroundStyle(.secondary)
                            .frame(width: 96, alignment: .leading)
                        Text(detail.text).font(.subheadline)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 11)
                    Divider()
                }
            }
        }
    }

    private var notes: some View {
        TextField("Add a note about \(person.name.split(separator: " ").first ?? "them")", text: $note, axis: .vertical)
            .font(.subheadline)
            .lineLimit(3...8)
            .focused($editingNote)
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private var activity: some View {
        if encounters.isEmpty {
            Text("You haven't met yet. Identify them with your glasses to start a history.")
                .font(.subheadline).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(encounters.reversed().enumerated()), id: \.offset) { index, date in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            Circle().fill(index == 0 ? Color.primary : Color(.tertiaryLabel)).frame(width: 7, height: 7).padding(.top, 6)
                            if index < encounters.count - 1 {
                                Rectangle().fill(Color(.separator)).frame(width: 1).frame(maxHeight: .infinity)
                            }
                        }
                        .frame(width: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recognized with glasses").font(.subheadline)
                            Text(dayAndTime(date) + " · " + relative(date))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 14)
                    }
                }
            }
        }
    }

    private var recognition: some View {
        VStack(spacing: 0) {
            NavigationLink { EnrollView(person: person) } label: {
                HStack {
                    Text("Face photos").font(.subheadline)
                    Spacer()
                    Text("\(store.samples(person.id))").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
            if store.samples(person.id) > 0 {
                Button("Remove face photos", role: .destructive) { store.reset(person.id) }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 11)
            }
        }
    }

    private func label(_ kind: Person.Kind) -> String {
        switch kind {
        case .school: "School"
        case .work: "Work"
        case .from: "From"
        case .interests: "Interests"
        }
    }
}

struct EnrollView: View {
    @Environment(Store.self) private var store
    @State private var model = CameraModel()
    @State private var picks: [PhotosPickerItem] = []
    @State private var flash = false
    let person: Person

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraPreview(session: model.camera.session).ignoresSafeArea()
                .overlay(Color.white.opacity(flash ? 0.5 : 0).ignoresSafeArea())
            VStack(spacing: 12) {
                Text(status).padding(.horizontal, 14).padding(.vertical, 8).background(.thinMaterial, in: Capsule())
                HStack(spacing: 24) {
                    PhotosPicker(selection: $picks, matching: .images) {
                        Image(systemName: "photo.on.rectangle").font(.title2).frame(width: 56, height: 56)
                            .background(.thinMaterial, in: Circle())
                    }
                    Button(action: capture) {
                        Circle().fill(.white).frame(width: 72, height: 72)
                            .overlay(Circle().stroke(.black.opacity(0.2), lineWidth: 2))
                    }
                    .disabled(model.faces.count != 1)
                    .opacity(model.faces.count == 1 ? 1 : 0.4)
                    Button { model.flip() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title2).frame(width: 56, height: 56)
                            .background(.thinMaterial, in: Circle())
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: picks) { _, items in importPhotos(items) }
    }

    private var status: String {
        let count = "\(store.samples(person.id)) saved"
        switch model.faces.count {
        case 0: return "No face · \(count)"
        case 1: return "Tap to save · \(count)"
        default: return "One face only · \(count)"
        }
    }

    private func capture() {
        guard model.faces.count == 1, let face = model.faces.first else { return }
        store.enroll(person.id, face)
        withAnimation(.easeOut(duration: 0.15)) { flash = true }
        withAnimation(.easeIn(duration: 0.25).delay(0.15)) { flash = false }
    }

    /// Library photos: keep only the largest face in each.
    private func importPhotos(_ items: [PhotosPickerItem]) {
        Task {
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = CIImage(data: data, options: [.applyOrientationProperty: true]),
                      let face = FaceEngine.faces(in: image).first else { continue }
                store.enroll(person.id, face)
            }
            picks = []
        }
    }
}


#if DEBUG
/// The simulated glasses' lens, mirrored into the app (phone-sim mode).
struct MockLens: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView {
        // SwiftUI's blend mode cannot reach into a UIKit view, so the lens's black is cleared
        // here instead: over the camera it has to be glass, not a black square.
        view.backgroundColor = .clear
        view.isOpaque = false
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// What the real glasses are showing, redrawn on the phone at the lens's own scale.
///
/// A real pair gives no readback — the SDK's preview view exists only for a simulated one, and the
/// SDK will not even initialise in the Simulator — so this cannot be a screenshot of the lens.
/// It is the next best thing: the same `LensShot` the card was built from, captured at the moment
/// of the send, laid out on a 600 x 600 canvas (the real panel) with the real card's own numbers —
/// the paddings, spacings, photo size and row order from `LensCards`, not a phone-ish redesign.
/// The whole canvas is then scaled into the tile, so the tile is a shrunken lens rather than a
/// small iOS view: proportions, line breaks and emphasis land where they land on glass.
///
/// What is guaranteed identical: the words, their order, which line is emphasised, the photo, the
/// counter badge (literally the same bitmap `LensCards` sends) and the button label. What is a
/// likeness: the typeface and the exact glyph weights, which are Meta's and live on the device.
/// Every number below is a UserDefaults knob, so the fit can be trued up against real glasses
/// with `tools/qm-tune.sh` and no rebuild.
struct LensMetrics {
    /// The real panel: 600 x 600, right eye.
    static let canvas: CGFloat = 600

    let heading = tune("mirrorHeading", 34)
    let body = tune("mirrorBody", 25)
    let meta = tune("mirrorMeta", 21)
    /// `sizePreset: .icon` — the photo and the counter badge are both sent at this size.
    let icon = tune("mirrorIcon", 56)
    let glyph = tune("mirrorGlyph", 28)
    let pad = tune("mirrorPad", 22)
    let radius = tune("mirrorRadius", 27)
    /// The gap the real renderer leaves under the card. Measured off a captured lens frame:
    /// 30 px of a 531 px panel, which is 34 of the lens's own 600.
    let bottom = tune("mirrorBottom", 34)

    private static func tune(_ key: String, _ fallback: CGFloat) -> CGFloat {
        CGFloat(Tuning.float(key, Float(fallback)))
    }
}

struct LensMirror: View {
    let shot: LensShot
    let avatar: (String) -> UIImage?

    private let m = LensMetrics()
    /// Measured, not guessed: `.secondary` text came back at 211 of 255 on a captured frame.
    /// The lens has no colour and very little contrast range, so "dimmer" is a small step.
    private let secondary = Color(white: 0.83)

    var body: some View {
        // Author everything in lens units, then shrink the finished panel into the tile.
        //
        // The card does NOT fill the panel. On a captured lens frame it hugs its own content,
        // runs edge to edge horizontally, and sits on the floor of the panel with a small gap
        // under it — so a two-line card is a strip at the bottom and a full identity card grows
        // upward from the same baseline. Everything above it is glass you can see through.
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                card
                Color.clear.frame(height: m.bottom)
            }
            .frame(width: LensMetrics.canvas, height: LensMetrics.canvas, alignment: .bottom)
            .scaleEffect(geo.size.width / LensMetrics.canvas, anchor: .topLeading)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
    }

    /// Mirror of `LensCards.groupRow`.
    private var groupRow: some View {
        HStack(spacing: 18) {
            if shot.meSpeaking {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left").font(.system(size: m.glyph))
                    Text("You").font(.system(size: m.meta))
                }
            }
            ForEach(shot.group.prefix(3), id: \.id) { member in
                HStack(spacing: 8) {
                    memberMark(member)
                    Text(member.name).font(.system(size: m.meta))
                        .foregroundStyle(member.speaking ? Color.white : secondary)
                }
            }
            if shot.group.count > 3 {
                Text("+\(shot.group.count - 3)").font(.system(size: m.meta)).foregroundStyle(secondary)
            }
        }
    }

    @ViewBuilder private func memberMark(_ member: Member) -> some View {
        if member.speaking {
            Image(systemName: "bubble.left").font(.system(size: m.glyph))
        } else if let photo = avatar(member.id) {
            Image(uiImage: photo)
                .resizable().aspectRatio(contentMode: .fill)
                .frame(width: m.icon, height: m.icon)
                .clipShape(RoundedRectangle(cornerRadius: m.icon * 0.22, style: .continuous))
        }
    }

    /// The aid's card content: the answer or definition, work in flight, the line to say next.
    @ViewBuilder private var aidBody: some View {
        VStack(alignment: .leading, spacing: 12) {
                if let title = shot.answer {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            if let icon = shot.cardIcon { Image(systemName: LensCards.symbol(lensIcon: icon)).font(.system(size: m.glyph)) }
                            Text(title).font(.system(size: m.heading, weight: .semibold))
                        }
                        if let detail = shot.echo {
                            Text(detail).font(.system(size: m.body)).foregroundStyle(secondary)
                        }
                    }
                }
                ForEach(Array(shot.working.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles").font(.system(size: m.glyph))
                        Text(line).font(.system(size: m.meta)).foregroundStyle(secondary)
                    }
                }
                if let followup = shot.followup {
                    HStack(spacing: 10) {
                        Image(systemName: "bubble.left").font(.system(size: m.glyph))
                        Text(followup).font(.system(size: m.body))
                    }
                }
        }
    }

    @ViewBuilder private var card: some View {
        switch shot.kind {
        case .split:
            // The lens split: the aid's card on top, who you're talking to at the bottom.
            VStack(alignment: .leading, spacing: 12) {
                if shot.answer != nil || !shot.working.isEmpty || shot.followup != nil {
                    aidBody
                        .padding(m.pad)
                        .modifier(LensCardBackground(radius: m.radius))
                }
                Spacer(minLength: 0)
                if shot.group.count >= 2 {
                    groupRow
                        .padding(m.pad)
                        .modifier(LensCardBackground(radius: m.radius))
                } else if let id = shot.photo {
                    HStack(alignment: .top, spacing: 16) {
                        // A third of the row, as on the lens; grey until the photo's write lands.
                        if shot.photoPending {
                            RoundedRectangle(cornerRadius: m.icon * 0.3, style: .continuous)
                                .fill(Color(white: 0.28))
                                .frame(width: m.icon * 2, height: m.icon * 2)
                        } else if let photo = avatar(id) {
                            Image(uiImage: photo)
                                .resizable().aspectRatio(contentMode: .fill)
                                .frame(width: m.icon * 2, height: m.icon * 2)
                                .clipShape(RoundedRectangle(cornerRadius: m.icon * 0.3, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(shot.name ?? "").font(.system(size: m.heading, weight: .semibold))
                            Text(shot.headline ?? "").font(.system(size: m.body))
                            if let context = shot.context {
                                Text(context).font(.system(size: m.meta)).foregroundStyle(secondary)
                            }
                        }
                    }
                    .padding(m.pad)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(LensCardBackground(radius: m.radius))
                }
            }

        case .aid:
            VStack(alignment: .leading, spacing: 12) {
                if shot.group.count >= 2 {
                    groupRow
                } else if let id = shot.photo {
                    HStack(spacing: 10) {
                        if let photo = avatar(id) {
                            Image(uiImage: photo)
                                .resizable().aspectRatio(contentMode: .fill)
                                .frame(width: m.icon, height: m.icon)
                                .clipShape(RoundedRectangle(cornerRadius: m.icon * 0.22, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shot.name ?? "").font(.system(size: m.meta))
                            Text(shot.headline ?? "").font(.system(size: m.meta)).foregroundStyle(secondary)
                        }
                    }
                } else if let header = shot.name {
                    Text(header).font(.system(size: m.meta)).foregroundStyle(secondary)
                }
                aidBody
            }
            .padding(m.pad)
            .modifier(LensCardBackground(radius: m.radius))

        case .compact where shot.group.count >= 2:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(shot.group.prefix(3), id: \.id) { member in
                    HStack(spacing: 12) {
                        memberMark(member)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.name).font(.system(size: m.body))
                                .foregroundStyle(member.speaking || !shot.meSpeaking ? Color.white : secondary)
                            Text(member.headline).font(.system(size: m.meta)).foregroundStyle(secondary)
                        }
                    }
                }
                if shot.group.count > 3 {
                    Text("+\(shot.group.count - 3) more").font(.system(size: m.meta)).foregroundStyle(secondary)
                }
            }
            .padding(m.pad)
            .modifier(LensCardBackground(radius: m.radius))

        case .compact:
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    if let id = shot.photo, let photo = avatar(id) {
                        Image(uiImage: photo)
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: m.icon, height: m.icon)
                            .clipShape(RoundedRectangle(cornerRadius: m.icon * 0.22, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shot.name ?? "").font(.system(size: m.body))
                        Text(shot.headline ?? "").font(.system(size: m.meta)).foregroundStyle(secondary)
                    }
                }
            }
            .padding(m.pad)
            .modifier(LensCardBackground(radius: m.radius))

        case .person:
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    // The lens gives the photo a third of the card; until its write lands, the same
                    // box holds a grey placeholder.
                    if shot.photoPending {
                        RoundedRectangle(cornerRadius: m.icon * 0.3, style: .continuous)
                            .fill(Color(white: 0.28))
                            .frame(width: m.icon * 2, height: m.icon * 2)
                    } else if let id = shot.photo, let photo = avatar(id) {
                        Image(uiImage: photo)
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: m.icon * 2, height: m.icon * 2)
                            .clipShape(RoundedRectangle(cornerRadius: m.icon * 0.3, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(shot.name ?? "").font(.system(size: m.heading, weight: .semibold))
                        // Exactly one line is .body on the lens — what they do now — and the eye
                        // finds it because nothing else on the card looks like it. Same here.
                        Text(shot.headline ?? "").font(.system(size: m.body))
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(shot.primary.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: m.meta))
                    }
                    ForEach(Array(shot.details.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 10) {
                            Image(systemName: row.icon).font(.system(size: m.glyph))
                            Text(row.text).font(.system(size: m.body))
                        }
                    }
                    ForEach(Array(shot.secondary.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: m.meta)).foregroundStyle(secondary)
                    }
                }
            }
            .padding(m.pad)
            .modifier(LensCardBackground(radius: m.radius))

        case .message:
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(shot.title ?? "").font(.system(size: m.heading, weight: .semibold))
                    if let subtitle = shot.subtitle {
                        Text(subtitle).font(.system(size: m.meta)).foregroundStyle(secondary)
                    }
                }
            }
            .padding(m.pad)
            .modifier(LensCardBackground(radius: m.radius))

        case .idle:
            // Nobody identified: the row floats on glass with no card behind it, and sits on the
            // same floor the card would — on a captured frame its glyphs stop 33 lens units from
            // the bottom edge, which is the panel inset and nothing else.
            EmptyView()
        }
    }

}

/// The lens's `.background(.card)`. Sampled straight off a captured lens frame rather than
/// invented: the fill is a flat slate #27282D with no border at all, the corners are ~27 lens
/// units, and the panel runs the full width of the display — it is cut off by the edge of the
/// glass, not inset from it.
private struct LensCardBackground: ViewModifier {
    let radius: CGFloat
    /// Measured (39, 40, 45) on the real renderer. Not black, and slightly blue.
    static let fill = Color(red: 39 / 255, green: 40 / 255, blue: 45 / 255)

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Self.fill)
            )
    }
}

/// Where the lens lands in a camera frame, from the two devices' optics.
///
/// Published figures, each a live knob so a real capture can true them up with no rebuild:
/// - The display is 600 x 600 at 42 pixels per degree (`lensPPD`): ~14.3° a side, the "20°
///   diagonal" Meta quotes.
/// - The camera is a 12 MP ultra-wide with a 100° field (`cameraFov`), taken here as the diagonal
///   of its 3:4 sensor. The stream is a 9:16 centre crop of that sensor, so the focal length in
///   stream pixels follows from the frame's long side alone: 671 px at 1280.
/// - The display sits in the right lens slightly below and right of straight ahead (UploadVR,
///   Tom's Guide). No one publishes the angle, so `lensRightDeg` / `lensDownDeg` default to a
///   few degrees and are the numbers to measure.
/// The camera is on the left of the frame and the eye behind the right lens, ~6 cm apart, which
/// is under a degree beyond 4 m and is ignored. A pinhole model: fine near the centre, where the
/// lens is; the ultra-wide's barrel distortion would only matter at the frame's edges.
struct LensOptics {
    let frame: CGSize

    var cameraFov: CGFloat { CGFloat(Tuning.float("cameraFov", 100)) }
    var ppd: CGFloat { CGFloat(Tuning.float("lensPPD", 42)) }
    var rightDeg: CGFloat { CGFloat(Tuning.float("lensRightDeg", 4)) }
    var downDeg: CGFloat { CGFloat(Tuning.float("lensDownDeg", 3)) }

    /// Focal length in frame pixels. Half the 3:4 sensor's diagonal is 0.625 of its long side.
    var focal: CGFloat {
        let long = max(frame.width, frame.height)
        return 0.625 * long / tan(cameraFov / 2 * .pi / 180)
    }

    /// How wide the 600 px panel is, as an angle.
    var lensDegrees: CGFloat { LensMetrics.canvas / ppd }

    /// The angle a centred span of frame pixels covers.
    func degrees(_ pixels: CGFloat) -> CGFloat { 2 * atan(pixels / 2 / focal) * 180 / .pi }

    /// The panel's side in frame pixels.
    var side: CGFloat { 2 * focal * tan(lensDegrees / 2 * .pi / 180) }

    var center: CGPoint {
        CGPoint(x: frame.width / 2 + focal * tan(rightDeg * .pi / 180),
                y: frame.height / 2 + focal * tan(downDeg * .pi / 180))
    }
}

/// Ground truth, pulled off the phone.
///
/// While a simulated pair is up, both renderers are alive at once: MockDeviceKit's preview view is
/// the SDK drawing the very `FlexBox` the glass would get, and `LensMirror` is our redraw of the
/// same card. With `SnapLens` set (a live knob, no rebuild) this writes both to the app's Documents
/// at the same size, so `devicectl device copy from` can pull them and the mirror can be trued
/// against the real thing from a laptop, with nobody squinting at a phone.
enum LensSnapshot {
    @MainActor static func capture(real: UIView?, shot: LensShot?, avatar: @escaping (String) -> UIImage?) {
        guard Tuning.bool("SnapLens", false) else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var size = CGSize(width: LensMetrics.canvas, height: LensMetrics.canvas)
        if let real, real.bounds.width > 1 {
            size = real.bounds.size
            let image = UIGraphicsImageRenderer(bounds: real.bounds).image { _ in
                real.drawHierarchy(in: real.bounds, afterScreenUpdates: false)
            }
            try? image.pngData()?.write(to: docs.appendingPathComponent("lens-real.png"))
        }
        guard let shot else { return }
        // Same pixel size as the real capture, so the two PNGs diff directly.
        let renderer = ImageRenderer(content:
            LensMirror(shot: shot, avatar: avatar)
                .frame(width: size.width, height: size.height)
                .background(Color.black))
        renderer.scale = 1
        if let image = renderer.uiImage {
            try? image.pngData()?.write(to: docs.appendingPathComponent("lens-mirror.png"))
        }
    }
}

/// Always-present frame around the lens, so anyone looking at the phone knows exactly what the
/// wearer sees and on which rig: the camera stream with the lens laid over it. Both are live with
/// real glasses: the picture is the actual stream off the pair, and the lens is a mirror —
/// the SDK offers a true preview view only for a simulated pair, so with real hardware the phone
/// redraws the same `LensShot` the card was sent from. Never a stale or invented card: when
/// nothing has been written to a lens, only its outline shows.
struct LensPanel: View {
    let lens: UIView?
    let pov: UIImage?
    let mocking: Bool
    let connected: Bool
    let identifying: Bool
    /// Why there's no picture, in words: starting, paused, reconnecting.
    var cameraNote: String = ""
    /// What was last written to the lens, for the mirror. Nil when nothing is on it.
    let shot: LensShot?
    let avatar: (String) -> UIImage?
    /// The pixel size of the frames off the camera; nil until the first one lands.
    var frameSize: CGSize? = nil

    private var state: (String, Color) {
        if identifying { return ("Looking", .orange) }
        if connected { return ("Live", .green) }
        return ("Off", Color(.tertiaryLabel))
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "eyeglasses").font(.system(size: 12, weight: .semibold))
                Text(mocking ? "Phone sim · camera + lens" : "Real glasses · camera + lens mirror")
                    .font(.caption.weight(.semibold))
                Spacer()
                Circle().fill(state.1).frame(width: 6, height: 6)
                Text(state.0).font(.caption2.weight(.medium))
            }
            .foregroundStyle(.secondary)

            // MIRROR_COMPARE=1 in the simulator puts the true renderer and the mirror side by
            // side on the same card — the only way to tell whether the replica is honest.
            if LensPanel.comparing, let lens {
                HStack(spacing: 8) {
                    tile("Lens · real") { MockLens(view: lens) }
                    tile("Lens · mirror") {
                        if let shot { LensMirror(shot: shot, avatar: avatar) }
                    }
                }
            } else {
                wearerView
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 2)
        // Debounced rather than rate-limited. A throttle here captured the *first* state after
        // launch and then silently dropped the real one a few hundred ms later, which looks
        // exactly like "the new build never shipped". Cancelling on change can't do that: the
        // last card always wins, and the preview view has had time to lay out.
        .task(id: shot) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            LensSnapshot.capture(real: lens, shot: shot, avatar: avatar)
        }
    }

    static let comparing = ProcessInfo.processInfo.environment["MIRROR_COMPARE"] == "1"

    /// `streamRes` high, the default: what the canvas is until a real frame says otherwise.
    private static let defaultFrame = CGSize(width: 720, height: 1280)

    /// What the wearer sees: the camera frame, with the lens laid over it.
    ///
    /// The camera is the frame's full width, 4:3, centred where the wearer is looking. The lens is
    /// deliberately NOT true to scale: at its real 14° it is a fingernail on a phone and the card
    /// can't be read. It is drawn large, centred in the lower two-thirds of the panel, and only the lower part of the 600 px panel is shown — the renderer
    /// stacks cards on the floor of the panel, so that is where everything is. `lensShown` is the
    /// share of the panel's height shown (0.6 = its bottom 360 px).
    ///
    /// Cards are drawn opaque rather than screen-blended: on a phone a see-through card over a
    /// busy scene is unreadable, which is the opposite of what the panel is for.
    private var wearerView: some View {
        let frame = frameSize ?? Self.defaultFrame
        let optics = LensOptics(frame: frame)
        let window: CGRect = {
            let height = min(frame.height, frame.width * 3 / 4)
            let y = min(max(optics.center.y - height / 2, 0), frame.height - height)
            return CGRect(x: 0, y: y, width: frame.width, height: height)
        }()
        let shown = LensMetrics.canvas * CGFloat(Tuning.float("lensShown", 0.6))
        return GeometryReader { geo in
            let k = geo.size.width / window.width
            let margin: CGFloat = 8
            // Two-thirds of the panel's height, and no wider than the panel.
            let scale = min((geo.size.height * 2 / 3 - margin) / shown,
                            (geo.size.width - 2 * margin) / LensMetrics.canvas)
            let box = CGSize(width: LensMetrics.canvas * scale, height: shown * scale)
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Color.black
                    if let pov {
                        Image(uiImage: pov).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: frame.width, height: frame.height)
                    } else {
                        Text(cameraNote.isEmpty ? (connected ? "Starting camera…" : "Not connected") : cameraNote)
                            .font(.system(size: 40)).foregroundStyle(Color(.systemGray))
                            .frame(width: frame.width, height: frame.height * 0.3)
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .offset(x: -window.minX, y: -window.minY)
                .frame(width: window.width, height: window.height, alignment: .topLeading)
                .clipped()
                .scaleEffect(k, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)

                // Laid out at the lens's own 600 and scaled, so line breaks land where they do on
                // glass; only the bottom `shown` of it is kept.
                Group {
                    if let lens {
                        MockLens(view: lens)
                    } else if let shot {
                        LensMirror(shot: shot, avatar: avatar)
                    }
                }
                .frame(width: LensMetrics.canvas, height: LensMetrics.canvas)
                .scaleEffect(scale, anchor: .bottom)
                .frame(width: box.width, height: box.height, alignment: .bottom)
                .clipped()
                .opacity(Double(Tuning.float("lensOpacity", 0.95)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                )
                .position(x: geo.size.width / 2, y: geo.size.height - margin - box.height / 2)
            }
        }
        .aspectRatio(window.width / window.height, contentMode: .fit)
        // Height from the full width, rather than squeezed by whatever height the stack offers.
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(.separator)))
    }

    private func tile<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 3) {
            ZStack {
                Color.black
                content()
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(.separator)))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
#endif

/// The pill row, in a view of its own: HomeView's body read `glasses.pov`, so it re-ran on every
/// camera frame (15–24 a second) and rebuilt the open Menu each time, which swallowed its taps —
/// "Real glasses" and the mic choice did nothing (20:47–20:58). Here only what the row shows is read.
struct HomeHeader: View {
    @Environment(Glasses.self) private var glasses
    @Environment(Assistant.self) private var assistant

    var body: some View {
        HStack {
            Menu {
                if glasses.connected {
                    Button("Disconnect glasses", role: .destructive) { glasses.disconnect() }
                } else {
                    Button("Connect glasses") { Task { await glasses.connect() } }
                }
                // The escape hatch if the watch misbehaves on stage: off, and the button is
                // the only way in again.
                Button {
                    glasses.watching.toggle()
                } label: {
                    Label("Auto-recognize", systemImage: glasses.watching ? "checkmark" : "eye.slash")
                }
                Section("Microphone") {
                    Button {
                        assistant.mic = .glasses
                    } label: {
                        Label("Glasses", systemImage: assistant.mic == .glasses ? "checkmark" : "eyeglasses")
                    }
                    Button {
                        assistant.mic = .phone
                    } label: {
                        Label("iPhone", systemImage: assistant.mic == .phone ? "checkmark" : "iphone")
                    }
                }
                #if DEBUG
                Section("Run on") {
                    Button {
                        Task { await glasses.useMock(false) }
                    } label: {
                        Label("Real glasses", systemImage: glasses.mocking ? "eyeglasses" : "checkmark")
                    }
                    Button {
                        Task { await glasses.useMock(true) }
                    } label: {
                        Label("This phone (simulated)", systemImage: glasses.mocking ? "checkmark" : "iphone")
                    }
                }
                #endif
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(glasses.connected ? Color.green : Color(.tertiaryLabel)).frame(width: 7, height: 7)
                    Text(glassesLabel)
                        .font(.footnote.weight(.medium))
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(.secondarySystemBackground), in: Capsule())
            }
            Button {
                Task { await assistant.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: assistant.armed ? "mic.fill" : "mic.slash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(assistant.armed ? Color.red : Color.secondary)
                    Text(assistant.armed ? "Listening" : "Mic off")
                        .font(.footnote.weight(.medium))
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(.secondarySystemBackground), in: Capsule())
            }
            Spacer()
            NavigationLink { StreamLabView() } label: {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(Color(.secondarySystemBackground), in: Circle())
            }
            NavigationLink { ConversationView() } label: {
                Image(systemName: "text.bubble")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(Color(.secondarySystemBackground), in: Circle())
            }
        }
        .tint(.primary)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    /// The pill says which rig is live, so nobody has to guess whether the glasses are real.
    private var glassesLabel: String {
        #if DEBUG
        if glasses.mocking { return glasses.connected ? "Phone sim" : "Phone sim off" }
        #endif
        return glasses.connected ? "Glasses on" : "Glasses off"
    }
}

#if DEBUG
/// The lens mirror and camera tile, reading the per-frame state itself so nothing around it redraws.
struct LiveLensPanel: View {
    @Environment(Store.self) private var store
    @Environment(Glasses.self) private var glasses

    var body: some View {
        LensPanel(lens: glasses.mockLens, pov: glasses.pov, mocking: glasses.mocking,
                  connected: glasses.connected, identifying: glasses.identifying,
                  cameraNote: glasses.cameraNote, shot: glasses.lensShot, avatar: { store.lensAvatar($0) },
                  frameSize: glasses.frameSize)
    }
}
#endif
