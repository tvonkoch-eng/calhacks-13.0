import CoreImage
import MWDATCamera
import MWDATCore
import MWDATDisplay
import MWDATInputs
import Observation
import UIKit

/// What the lens shows during a conversation: the question we heard and the answer so far.
struct AnswerCard: Equatable {
    let question: String
    let answer: String
    let thinking: Bool

    /// The lens is small. Echo just enough of the question to make the answer legible.
    var echo: String {
        let words = question.split(separator: " ")
        guard words.count > 7 else { return question }
        return words.prefix(7).joined(separator: " ") + "\u{2026}"
    }
}

enum Identification {
    case ready
    case noFace
    case unknown(FaceHit)
    case known(Match, FaceHit)
}

/// Meta glasses session. Press to identify (lens button, glasses capture button, or the phone):
/// match the newest camera frame, fall back to a full photo, and put the person's card on the lens.
@MainActor @Observable final class Glasses {
    var status = "Not connected"
    var connected = false
    var connecting = false
    var identifying = false
    var frame: UIImage?
    var result: Identification = .ready
    /// Takes over the lens while it is set; the identity card comes back when it clears.
    var answer: AnswerCard?

    @ObservationIgnored var store: Store?
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var camera: Camera?
    @ObservationIgnored private var display: Display?
    @ObservationIgnored private var displayReady = false
    @ObservationIgnored private var tokens: [any AnyListenerToken] = []
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var photoWaiter: CheckedContinuation<CIImage?, Never>?
    @ObservationIgnored private let worker = DispatchQueue(label: "glasses-faces")
    @ObservationIgnored private var lastSend = Date.distantPast
    @ObservationIgnored private var pendingSend: Task<Void, Never>?
    /// The lens link cannot take a frame per streamed token; coalesce to this cadence.
    @ObservationIgnored private let minSendInterval: TimeInterval = 0.22

    static func configure() {
        do { try Wearables.configure() } catch { print("Wearables.configure failed: \(error)") }
    }

    /// Meta AI calls back here after registration / permission; carry on connecting.
    func handle(_ url: URL) {
        guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(where: { $0.name == "metaWearablesAction" }) == true else { return }
        Task {
            _ = try? await Wearables.shared.handleUrl(url)
            await connect()
        }
    }

    func connectIfRegistered() async {
        if Wearables.shared.registrationState == .registered { await connect() }
    }

    func connect() async {
        guard !connected, !connecting else { return }
        connecting = true
        defer { connecting = false }
        let wearables = Wearables.shared
        do {
            if wearables.registrationState != .registered {
                status = "Approve in Meta AI…"
                try await wearables.startRegistration()
                return
            }
            if try await wearables.checkPermissionStatus(.camera) != .granted {
                status = "Allow camera in Meta AI…"
                guard try await wearables.requestPermission(.camera) == .granted else {
                    status = "Camera permission denied in Meta AI"
                    return
                }
            }
            let selector = AutoDeviceSelector(wearables: wearables)
            status = "Waiting for glasses…"
            for await id in selector.activeDeviceStream() {
                if id != nil { break }
            }

            status = "Starting session…"
            let session = try wearables.createSession(deviceSelector: selector)
            self.session = session
            tokens.append(session.statePublisher.listen { [weak self] state in
                guard state == .stopped else { return }
                Task { @MainActor in self?.teardown(status: "Glasses disconnected") }
            })
            let started = Task {
                for await state in session.stateStream() where state == .started { return }
            }
            try session.start()
            await started.value

            guard let camera = try session.addCamera(config: StreamConfiguration(videoCodec: .raw, resolution: .high, frameRate: 2)) else {
                status = "Glasses camera unavailable"
                return
            }
            tokens.append(camera.stream.videoFramePublisher.listen { [weak self] frame in
                guard let image = frame.makeUIImage() else { return }
                Task { @MainActor in self?.frame = image }
            })
            tokens.append(camera.stream.photoDataPublisher.listen { [weak self] photo in
                let image = CIImage(data: photo.data, options: [.applyOrientationProperty: true])
                Task { @MainActor in
                    self?.photoWaiter?.resume(returning: image)
                    self?.photoWaiter = nil
                }
            })
            tokens.append(camera.stream.errorPublisher.listen { [weak self] error in
                Task { @MainActor in self?.status = error.localizedDescription }
            })
            camera.stream.start()
            self.camera = camera

            if let id = selector.activeDevice, wearables.deviceForIdentifier(id)?.supportsDisplay() == true {
                let display = try session.addDisplay()
                tokens.append(display.statePublisher.listen { [weak self] state in
                    Task { @MainActor in
                        self?.displayReady = state == .started
                        self?.renderLens()
                    }
                })
                display.start()
                self.display = display
            }
            attachInputs(session)

            connected = true
            status = display == nil ? "Connected" : "Connected · lens on"
        } catch {
            status = "\(error)"
        }
    }

    func disconnect() {
        session?.stop()
        teardown(status: "Not connected")
    }

    func identify() async {
        guard connected, !identifying, let store else { return }
        identifying = true
        defer { identifying = false }

        var faces = await detect(frame.flatMap { CIImage(image: $0) })
        if faces.isEmpty, let photo = await capturePhoto() {
            faces = await detect(photo)
        }
        if let face = faces.first {
            result = store.match(face.embedding).map { .known($0, face) } ?? .unknown(face)
        } else {
            result = .noFace
        }
        renderLens()
    }

    /// Put a conversation answer on the lens, or clear it and fall back to the identity card.
    func showAnswer(_ card: AnswerCard?) {
        guard card != answer else { return }
        answer = card
        renderLens()
    }

    /// Re-match the last face after it was saved to someone.
    func rematch() {
        guard let store else { return }
        switch result {
        case .known(_, let face), .unknown(let face):
            result = store.match(face.embedding).map { .known($0, face) } ?? .unknown(face)
            renderLens()
        default: break
        }
    }

    private func teardown(status: String) {
        inputTask?.cancel()
        inputTask = nil
        tokens = []
        camera = nil
        display = nil
        displayReady = false
        session = nil
        connected = false
        pendingSend?.cancel()
        pendingSend = nil
        answer = nil
        frame = nil
        result = .ready
        photoWaiter?.resume(returning: nil)
        photoWaiter = nil
        self.status = status
    }

    /// Glasses capture button / action button → identify. Needs Inputs enabled in Wearables Developer Center.
    private func attachInputs(_ session: DeviceSession) {
        guard let inputs = try? session.addInputs(configuration: InputsConfiguration(consumeBack: false)) else { return }
        let events = inputs.events
        inputTask = Task { [weak self] in
            for await event in events {
                switch event {
                case .capture(.shortPress, _, _), .button(.action, _, _):
                    await self?.identify()
                default:
                    break
                }
            }
        }
    }

    private func detect(_ image: CIImage?) async -> [FaceHit] {
        guard let image else { return [] }
        return await withCheckedContinuation { done in
            worker.async { done.resume(returning: FaceEngine.faces(in: image)) }
        }
    }

    private func capturePhoto() async -> CIImage? {
        guard let stream = camera?.stream else { return nil }
        return await withCheckedContinuation { done in
            photoWaiter = done
            guard stream.capturePhoto(format: .jpeg) else {
                photoWaiter = nil
                done.resume(returning: nil)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(6))
                photoWaiter?.resume(returning: nil)
                photoWaiter = nil
            }
        }
    }

    private func renderLens() {
        guard displayReady else { return }

        // A live answer owns the lens. It is the thing the wearer needs in the next half second.
        if let card = answer {
            let headline = card.answer.isEmpty ? "\u{2026}" : card.answer
            send(FlexBox(direction: .column, spacing: 8) {
                Text(headline, style: .heading)
                Text(card.echo, style: .meta, color: .secondary)
            })
            return
        }

        let identify: @Sendable () -> Void = { [weak self] in Task { @MainActor in await self?.identify() } }
        let button = Button(label: "Identify", style: .secondary, iconName: .eye, onClick: identify)
        let view: FlexBox
        switch result {
        case .known(let match, _):
            let person = match.person
            let facts = Array(person.facts.prefix(2))
            view = FlexBox(direction: .column, spacing: 8) {
                Text(person.name, style: .heading)
                Text(person.role, style: .body, color: .secondary)
                for fact in facts { Text(fact, style: .meta) }
                button
            }
        case .unknown:
            view = FlexBox(direction: .column, spacing: 8) {
                Text("Not in your contacts", style: .heading)
                button
            }
        case .noFace:
            view = FlexBox(direction: .column, spacing: 8) {
                Text("No face found", style: .heading)
                Text("Face them and try again", style: .body, color: .secondary)
                button
            }
        case .ready:
            view = FlexBox(direction: .column, spacing: 8) {
                Text("Ready", style: .heading)
                Text("Look at someone, then identify", style: .body, color: .secondary)
                button
            }
        }
        send(view)
    }

    /// Rate-limited lens write. The first frame of an answer goes out immediately; the stream of
    /// token updates behind it collapses into one frame every `minSendInterval`, last value wins.
    private func send(_ view: FlexBox) {
        pendingSend?.cancel()
        let wait = minSendInterval - Date().timeIntervalSince(lastSend)
        guard wait > 0 else {
            lastSend = Date()
            Task { try? await display?.send(view.padding(20).background(.card)) }
            return
        }
        pendingSend = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, let display = self.display else { return }
            self.lastSend = Date()
            try? await display.send(view.padding(20).background(.card))
        }
    }
}
