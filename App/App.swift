import PhotosUI
import SwiftUI

@main
struct CalHacksApp: App {
    @State private var store = Store()
    @State private var glasses = Glasses()
    @State private var assistant = Assistant()

    init() {
        Glasses.configure()
        // Before anything reads a threshold: a pushed tuning.json is authoritative from launch.
        Tuning.shared.start()
        DispatchQueue.global(qos: .userInitiated).async { FaceEngine.warmUp() }
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(store)
                .environment(glasses)
                .environment(assistant)
                .onOpenURL { glasses.handle($0) }
                .task {
                    glasses.store = store
                    assistant.glasses = glasses
                    // Knobs that are read once rather than per use have to be re-applied by hand
                    // when a push lands; Store re-reads the roster on the same notification.
                    NotificationCenter.default.addObserver(forName: Tuning.changed, object: nil, queue: .main) { _ in
                        let wanted = Tuning.bool("AutoIdentify", glasses.watching)
                        if wanted != glasses.watching { glasses.watching = wanted }
                        // Resolution and frame rate are fixed when the camera is added, so a push
                        // needs a fresh camera to mean anything. Makes streamRes a 0.3 s change.
                        glasses.restreamIfSettingsChanged()
                    }
                    #if DEBUG
                    let env = ProcessInfo.processInfo.environment
                    if Glasses.prefersMock {
                        await glasses.useMockGlasses()
                        Task { await glasses.connect() }
                    }
                    // PREVIEW_SEEN="joaquin:7200,mirabelle:900" = seen that many seconds ago.
                    for entry in (ProcessInfo.processInfo.environment["PREVIEW_SEEN"] ?? "").split(separator: ",") {
                        let parts = entry.split(separator: ":")
                        if parts.count == 2, let seconds = Double(parts[1]) {
                            store.markSeen(String(parts[0]), at: .now.addingTimeInterval(-seconds))
                        }
                    }
                    if let id = ProcessInfo.processInfo.environment["PREVIEW_PERSON"],
                       let person = store.people.first(where: { $0.id == id }) {
                        glasses.preview(person)
                        if env["PREVIEW_CONFIRM"] == "1" { await glasses.lensIdentify(source: "preview") }
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
                LensPanel(lens: glasses.mockLens, pov: glasses.pov, mocking: glasses.mocking,
                          connected: glasses.connected, identifying: glasses.identifying,
                          shot: glasses.lensShot, avatar: { store.lensAvatar($0) })
                #endif
                header
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
                        notice
                            .padding(.horizontal, 20)
                            .padding(.bottom, 10)
                        if assistant.armed, let turn = assistant.current, turn.live || !turn.answer.isEmpty {
                            AnswerStrip(turn: turn)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 10)
                        }
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            VStack(spacing: 0) {
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

    private var header: some View {
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
                if assistant.armed { assistant.disarm() } else { Task { await assistant.arm() } }
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
            Button {
                Task { glasses.connected ? await glasses.identify() : await glasses.connect() }
            } label: {
                Text(buttonTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(.systemBackground))
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Color.primary, in: Capsule())
            }
            .disabled(glasses.identifying || glasses.connecting)
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
        if glasses.identifying { return "Recognizing" }
        return glasses.connected ? "Identify" : "Connect glasses"
    }
}

/// The question just heard and the answer that went to the lens.
struct AnswerStrip: View {
    let turn: Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(turn.question).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            Text(turn.answer.isEmpty ? "\u{2026}" : turn.answer)
                .font(.system(.body, design: .serif, weight: .medium))
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color(.separator)))
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
                        Text(person.tags?.prefix(2).joined(separator: " · ") ?? person.role)
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
    let person: Person
    @State private var note = ""
    @FocusState private var editingNote: Bool

    private var encounters: [Date] { store.encounters[person.id] ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                stats.padding(.top, 22)
                section("Details") { details }
                section("Notes") { notes }
                section("Activity") { activity }
                section("Recognition") { recognition }
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
    func makeUIView(context: Context) -> UIView { view }
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

    @ViewBuilder private var card: some View {
        switch shot.kind {
        case .answer:
            VStack(alignment: .leading, spacing: 8) {
                Text(shot.answer ?? "").font(.system(size: m.heading, weight: .semibold))
                if let echo = shot.echo {
                    Text(echo).font(.system(size: m.meta)).foregroundStyle(secondary)
                }
            }
            .padding(24)
            .modifier(LensCardBackground(radius: m.radius))

        case .person:
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    if let id = shot.photo, let photo = avatar(id) {
                        Image(uiImage: photo)
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: m.icon, height: m.icon)
                            .clipShape(RoundedRectangle(cornerRadius: m.icon * 0.22, style: .continuous))
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
                bottomRow
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
                bottomRow
            }
            .padding(m.pad)
            .modifier(LensCardBackground(radius: m.radius))

        case .idle:
            // Nobody identified: the row floats on glass with no card behind it, and sits on the
            // same floor the card would — on a captured frame its glyphs stop 33 lens units from
            // the bottom edge, which is the panel inset and nothing else.
            bottomRow.padding(.horizontal, 20)
        }
    }

    /// People met on the left, the one control on the right — the row the lens always carries,
    /// except behind an answer.
    private var bottomRow: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "person").font(.system(size: m.glyph))
                // The same UIImage the lens is sent, not a redraw of it.
                if let badge = LensCards.counterBadge(shot.connected) {
                    Image(uiImage: badge).resizable().frame(width: m.glyph, height: m.glyph)
                }
            }
            Spacer(minLength: 0)
            // The lens draws the primary button as a soft glow with white content — no filled
            // capsule, no dark label. A transparent display spends light on the glyphs, not on a
            // background, and the captured frame shows exactly that: the icon leads, the label
            // follows, and the only "fill" is a gradient that fades out to the right.
            HStack(spacing: 10) {
                Image(systemName: shot.buttonIcon).font(.system(size: m.glyph, weight: .semibold))
                Text(shot.button).font(.system(size: m.body, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.top, 26)
            .padding(.bottom, 8)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.17), Color.white.opacity(0)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            )
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
/// wearer sees and on which rig. Both tiles are live with real glasses: the camera tile is the
/// actual stream off the pair (5 fps, the Bluetooth budget), and the lens tile is a mirror —
/// the SDK offers a true preview view only for a simulated pair, so with real hardware the phone
/// redraws the same `LensShot` the card was sent from. Never a stale or invented card: when
/// nothing has been written to a lens, the tile says so.
struct LensPanel: View {
    let lens: UIView?
    let pov: UIImage?
    let mocking: Bool
    let connected: Bool
    let identifying: Bool
    /// What was last written to the lens, for the mirror. Nil when nothing is on it.
    let shot: LensShot?
    let avatar: (String) -> UIImage?

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

            // Camera on the left, lens on the right. They are different things: the camera is
            // what the glasses SEE, the lens is what they SHOW. Only ever showing the lens made
            // a correctly-black display look like a broken camera.
            HStack(spacing: 8) {
                tile("Camera") {
                    if let pov {
                        Image(uiImage: pov).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Text(connected ? "Waiting for frames" : "Not connected")
                            .font(.caption2).foregroundStyle(Color(.systemGray))
                    }
                }
                // MIRROR_COMPARE=1 in the simulator puts the true renderer and the mirror side
                // by side on the same card — the only way to tell whether the replica is honest.
                if LensPanel.comparing, let lens {
                    tile("Lens · real") { MockLens(view: lens) }
                    tile("Lens · mirror") {
                        if let shot { LensMirror(shot: shot, avatar: avatar) }
                    }
                } else {
                tile(lens == nil ? "Lens · mirror" : "Lens") {
                    if let lens {
                        MockLens(view: lens)
                    } else if let shot {
                        LensMirror(shot: shot, avatar: avatar)
                    } else {
                        Text(connected ? "No lens on this pair" : "Not connected")
                            .multilineTextAlignment(.center)
                            .font(.caption2).foregroundStyle(Color(.systemGray))
                    }
                }
                }
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
