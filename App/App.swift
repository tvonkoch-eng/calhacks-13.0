import PhotosUI
import SwiftUI

@main
struct CalHacksApp: App {
    @State private var store = Store()
    @State private var glasses = Glasses()
    @State private var assistant = Assistant()

    init() {
        Glasses.configure()
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
                    #if DEBUG
                    let env = ProcessInfo.processInfo.environment
                    if env["MOCK_GLASSES"] == "1" {
                        glasses.useMockGlasses()
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
                if let lens = glasses.mockLens {
                    MockLens(view: lens).aspectRatio(1, contentMode: .fit).frame(maxHeight: 360).background(Color.black)
                }
                #endif
                header
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
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(glasses.connected ? Color.green : Color(.tertiaryLabel)).frame(width: 7, height: 7)
                    Text(glasses.connected ? "Glasses on" : "Glasses off")
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

    /// One quiet line under the title: what's happening right now, if anything.
    @ViewBuilder private var notice: some View {
        if glasses.identifying {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Recognizing")
            }
            .font(.subheadline).foregroundStyle(.secondary)
        } else if case .noFace = glasses.result {
            Text("No one in view. Face them and try again.").font(.subheadline).foregroundStyle(.secondary)
        } else if !store.hasFaces {
            Text("Add photos so people can be recognized.").font(.subheadline).foregroundStyle(.secondary)
        } else if store.lastSeen.isEmpty {
            Text("Look at someone and press the button on your glasses.").font(.subheadline).foregroundStyle(.secondary)
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
/// The simulated glasses' lens, mirrored into the app (MOCK_GLASSES=1).
struct MockLens: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
