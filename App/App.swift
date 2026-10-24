import PhotosUI
import SwiftUI

@main
struct CalHacksApp: App {
    @State private var store = Store()
    @State private var glasses = Glasses()
    @State private var assistant = Assistant()

    init() { Glasses.configure() }

    var body: some Scene {
        WindowGroup {
            GlassesView()
                .environment(store)
                .environment(glasses)
                .environment(assistant)
                .onOpenURL { glasses.handle($0) }
                .task {
                    glasses.store = store
                    assistant.glasses = glasses
                    await glasses.connectIfRegistered()
                }
        }
    }
}

struct GlassesView: View {
    @Environment(Store.self) private var store
    @Environment(Glasses.self) private var glasses
    @Environment(Assistant.self) private var assistant

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ZStack {
                    if let frame = glasses.frame {
                        Image(uiImage: frame).resizable().scaledToFill()
                    } else {
                        Color(.secondarySystemBackground)
                        Image(systemName: "eyeglasses").font(.system(size: 44)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                resultCard
                Spacer()
                listenStrip

                if glasses.connected {
                    Button { Task { await glasses.identify() } } label: {
                        Label(glasses.identifying ? "Identifying…" : "Identify", systemImage: "eye")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 54)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(glasses.identifying)
                } else {
                    Button { Task { await glasses.connect() } } label: {
                        Label(glasses.connecting ? "Connecting…" : "Connect glasses", systemImage: "eyeglasses")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 54)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(glasses.connecting)
                }
                Text(glasses.status).font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Glasses")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if glasses.connected { Button("Disconnect") { glasses.disconnect() } }
                }
                ToolbarItem { NavigationLink("People") { PeopleView() } }
                ToolbarItem(placement: .bottomBar) {
                    NavigationLink("Transcript") { ConversationView() }
                }
            }
        }
    }

    /// Mic state plus the question in flight. Tap through for the full log and timings.
    @ViewBuilder private var listenStrip: some View {
        VStack(spacing: 8) {
            MicRow()
            if let turn = assistant.current, turn.live || !turn.answer.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(turn.question).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(turn.answer.isEmpty ? "…" : turn.answer)
                            .font(.subheadline.weight(.medium)).lineLimit(2)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var resultCard: some View {
        switch glasses.result {
        case .ready:
            Text("Look at someone, then tap Identify or press the capture button on your glasses.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        case .noFace:
            MessageCard(title: "No face found", detail: "Face the person and try again.")
        case .unknown(let face):
            MessageCard(title: "Not in your contacts", detail: nil) { SaveFaceMenu(face: face, label: "Save as…") }
        case .known(let match, let face):
            VStack(alignment: .trailing, spacing: 6) {
                MatchCard(match: match)
                SaveFaceMenu(face: face, label: "Wrong person?").font(.footnote)
            }
        }
    }
}

struct MessageCard<Accessory: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder var accessory: () -> Accessory

    init(title: String, detail: String?, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.accessory = accessory
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer()
            accessory()
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
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

struct PeopleView: View {
    @Environment(Store.self) private var store

    var body: some View {
        List {
            Section {
                ForEach(store.contacts) { person in
                    NavigationLink(value: person) { PersonRow(person: person) }
                }
            }
            if let me = store.me {
                Section("You") {
                    NavigationLink(value: me) { PersonRow(person: me) }
                }
            }
        }
        .navigationTitle("People")
        .navigationDestination(for: Person.self) { PersonView(person: $0) }
    }
}

struct Avatar: View {
    @Environment(Store.self) private var store
    let person: Person
    var size: CGFloat = 44

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
        .clipShape(Circle())
    }
}

struct PersonRow: View {
    @Environment(Store.self) private var store
    let person: Person

    var body: some View {
        HStack(spacing: 12) {
            Avatar(person: person)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.body.weight(.medium))
                Text(person.role).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if store.samples(person.id) == 0 {
                Text("No face").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

struct PersonView: View {
    @Environment(Store.self) private var store
    let person: Person

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Avatar(person: person, size: 72)
                    VStack(alignment: .leading) {
                        Text(person.name).font(.title2.weight(.semibold))
                        Text(person.role).foregroundStyle(.secondary)
                    }
                }
            }
            if !person.facts.isEmpty {
                Section("About") {
                    ForEach(person.facts, id: \.self) { Text($0) }
                }
            }
            Section {
                NavigationLink("Add face photos") { EnrollView(person: person) }
                if store.samples(person.id) > 0 {
                    Button("Clear face photos", role: .destructive) { store.reset(person.id) }
                }
            } footer: {
                Text("\(store.samples(person.id)) face samples")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MatchCard: View {
    let match: Match?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let match {
                Avatar(person: match.person, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(match.person.name).font(.headline)
                        Spacer()
                        Text(match.score, format: .number.precision(.fractionLength(2)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(match.person.role).font(.subheadline).foregroundStyle(.secondary)
                    ForEach(match.person.facts.prefix(3), id: \.self) { Text($0).font(.footnote) }
                }
            } else {
                Text("Unknown").font(.headline).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
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
