import PhotosUI
import SwiftUI

@main
struct CalHacksApp: App {
    @State private var store = Store()
    @State private var glasses = Glasses()

    init() { Glasses.configure() }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(store)
                .environment(glasses)
                .onOpenURL { glasses.handle($0) }
                .task {
                    glasses.store = store
                    #if DEBUG
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
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(.smooth(duration: 0.3), value: glasses.identifying)
                actionButton
            }
            .background(Color(.systemBackground))
            .toolbar(.hidden, for: .navigationBar)
        }
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
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(.secondarySystemBackground), in: Capsule())
            }
            Spacer()
            NavigationLink { PeopleView() } label: {
                Image(systemName: "person.2")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(Color(.secondarySystemBackground), in: Circle())
            }
        }
        .tint(.primary)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @ViewBuilder private var content: some View {
        if glasses.identifying {
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Recognizing").font(.headline).foregroundStyle(.secondary)
            }
        } else {
            switch glasses.result {
            case .known(let match, let face):
                ScrollView {
                    ProfileView(person: match.person, face: face)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 28)
                }
                .scrollIndicators(.hidden)
            case .ready:
                EmptyState(symbol: "eyeglasses",
                           title: "Look at someone",
                           detail: glasses.connected
                               ? "Press the capture button on your glasses, or tap Identify."
                               : "Put on your glasses and connect to get started.")
            case .noFace:
                EmptyState(symbol: "person.crop.circle.badge.questionmark",
                           title: "No one in view",
                           detail: "Face them and try again.")
            case .unknown:
                EmptyState(symbol: "person.crop.circle.badge.plus",
                           title: "No one saved yet",
                           detail: "Add photos of the people you want to recognize.")
            }
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
        .padding(.bottom, 12)
    }

    private var buttonTitle: String {
        if glasses.connecting { return "Connecting" }
        if glasses.identifying { return "Recognizing" }
        return glasses.connected ? "Identify" : "Connect glasses"
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 52, weight: .ultraLight))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            Text(title).font(.system(.title2, design: .serif, weight: .semibold))
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
    }
}

/// The identified person: photo, name, background as ruled rows, and an opener.
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

            if let opener = person.opener {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SAY HI")
                        .font(.caption.weight(.semibold)).tracking(0.8)
                        .foregroundStyle(.secondary)
                    Text(opener).font(.system(.title3, design: .serif))
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.top, 24)
            }

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
    let person: Person

    var body: some View {
        HStack(spacing: 12) {
            Avatar(person: person)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.body.weight(.medium))
                Text(person.role).font(.subheadline).foregroundStyle(.secondary)
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

