import PhotosUI
import SwiftUI

@main
struct CalHacksApp: App {
    @State private var store = Store()
    @State private var glasses = Glasses()

    init() {
        Glasses.configure()
        DispatchQueue.global(qos: .userInitiated).async { FaceEngine.warmUp() }
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(store)
                .environment(glasses)
                .onOpenURL { glasses.handle($0) }
                .task {
                    glasses.store = store
                    #if DEBUG
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Contacts")
                            .font(.system(size: 34, weight: .semibold, design: .serif))
                            .padding(.horizontal, 20)
                            .padding(.top, 10)
                            .padding(.bottom, 6)
                        notice
                            .padding(.horizontal, 20)
                            .padding(.bottom, 10)
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            VStack(spacing: 0) {
                                ForEach(Array(store.recents.enumerated()), id: \.element.id) { index, person in
                                    if index == 0, isCurrent(person, now: context.date) {
                                        CurrentCard(person: person)
                                            .padding(.horizontal, 16)
                                            .padding(.bottom, 8)
                                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                                    } else {
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
                actionButton
            }
            .background(Color(.systemBackground))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Person.self) { PersonView(person: $0) }
        }
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
            Spacer()
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

/// The person you're talking to now: photo and who they are.
struct CurrentCard: View {
    @Environment(Store.self) private var store
    @Environment(Glasses.self) private var glasses
    let person: Person

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: person) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 14) {
                        Avatar(person: person, size: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("NOW")
                                .font(.caption2.weight(.bold)).tracking(1)
                                .foregroundStyle(.green)
                            Text(person.name).font(.system(.title2, design: .serif, weight: .semibold))
                            Text(person.role).font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
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
    let person: Person
    let seen: Date?
    let now: Date

    var body: some View {
        NavigationLink(value: person) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Avatar(person: person, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name).font(.body.weight(.medium))
                        Text(person.role).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(seenText).font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
                Divider().padding(.leading, 62)
            }
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var seenText: String {
        guard let seen else { return "" }
        if now.timeIntervalSince(seen) < 60 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: seen, relativeTo: now)
    }
}

/// A person's profile: photo, name, and background as ruled rows.
struct ProfileView: View {
    @Environment(Store.self) private var store
    let person: Person
    let face: FaceHit?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let image = store.avatars[person.id] {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color(.secondarySystemBackground)
                        .overlay(Text(person.name.prefix(1)).font(.system(size: 48, design: .serif)))
                }
            }
            .frame(width: 112, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .padding(.bottom, 20)

            Text(person.name)
                .font(.system(size: 34, weight: .semibold, design: .serif))
            Text(person.role)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .padding(.bottom, 24)

            ForEach(person.details, id: \.text) { detail in
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(label(detail.kind))
                        .font(.caption.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                        .frame(width: 86, alignment: .leading)
                    Text(detail.text).font(.body)
                }
                .padding(.vertical, 14)
            }
            Divider()

            if let face {
                SaveFaceMenu(face: face, label: "Not \(person.name.split(separator: " ").first ?? "them")?")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 18)
            }
        }
    }

    private func label(_ kind: Person.Kind) -> String {
        switch kind {
        case .school: "SCHOOL"
        case .work: "WORK"
        case .from: "FROM"
        case .interests: "INTO"
        }
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

struct PersonView: View {
    @Environment(Store.self) private var store
    let person: Person

    var body: some View {
        List {
            Section {
                ProfileView(person: person, face: nil)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
            }
            Section {
                NavigationLink("Add photos") { EnrollView(person: person) }
                if store.samples(person.id) > 0 {
                    Button("Remove photos", role: .destructive) { store.reset(person.id) }
                }
            } footer: {
                Text(store.samples(person.id) == 1 ? "1 photo" : "\(store.samples(person.id)) photos")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
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

