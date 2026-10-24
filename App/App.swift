import PhotosUI
import SwiftUI

@main
struct CalHacksApp: App {
    @State private var store = Store()
    @State private var glasses = Glasses()

    init() { Glasses.configure() }

    var body: some Scene {
        WindowGroup {
            PeopleView()
                .environment(store)
                .environment(glasses)
                .onOpenURL { Glasses.handle($0) }
        }
    }
}

struct PeopleView: View {
    @Environment(Store.self) private var store

    var body: some View {
        NavigationStack {
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
            .safeAreaInset(edge: .bottom) {
                NavigationLink { ScanView() } label: {
                    Label("Scan", systemImage: "viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .padding()
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

struct ScanView: View {
    @Environment(Store.self) private var store
    @Environment(Glasses.self) private var glasses
    @State private var model = CameraModel()
    @AppStorage("useGlasses") private var useGlasses = false

    private var faces: [FaceHit] { useGlasses ? glasses.faces : model.faces }

    var body: some View {
        @Bindable var store = store
        ZStack(alignment: .bottom) {
            if useGlasses {
                Group {
                    if let frame = glasses.frame {
                        Image(uiImage: frame).resizable().scaledToFill()
                    } else {
                        Color.black
                    }
                }
                .ignoresSafeArea()
            } else {
                CameraPreview(session: model.camera.session).ignoresSafeArea()
            }
            VStack(spacing: 8) {
                if useGlasses && !glasses.connected {
                    Button("Connect glasses") { Task { await glasses.connect() } }
                        .buttonStyle(.borderedProminent)
                    Text(glasses.status).font(.footnote).padding(8).background(.thinMaterial, in: Capsule())
                } else if faces.isEmpty {
                    Text("Point at someone").padding().background(.thinMaterial, in: Capsule())
                }
                ForEach(Array(faces.prefix(3).enumerated()), id: \.offset) { _, face in
                    MatchCard(match: store.match(face.embedding))
                }
                HStack {
                    Text("Strictness").font(.caption)
                    Slider(value: $store.threshold, in: 0.5...0.98)
                    Text(store.threshold, format: .number.precision(.fractionLength(2))).font(.caption.monospacedDigit())
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
            }
            .padding()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Source", selection: $useGlasses) {
                    Text("Phone").tag(false)
                    Text("Glasses").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            if !useGlasses {
                ToolbarItem { Button { model.flip() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera") } }
            } else if glasses.connected {
                ToolbarItem { Button("Disconnect") { glasses.disconnect() } }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !useGlasses { model.start() } }
        .onDisappear { model.stop() }
        .onChange(of: useGlasses) { _, glassesOn in glassesOn ? model.stop() : model.start() }
        .onChange(of: faces.first.flatMap { store.match($0.embedding)?.person }) { _, person in
            if let person, useGlasses { glasses.show(person) }
        }
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
