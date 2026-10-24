import CoreImage
import MWDATCamera
import MWDATCore
import MWDATDisplay
import MWDATInputs
import Observation
import UIKit

enum Identification {
    case ready
    case noFace
    case unknown(FaceHit)
    case known(Match, FaceHit?)
}

/// Meta glasses session. Nothing streams: pressing Identify (lens button, glasses capture
/// button, or the phone) takes one photo, matches the largest face, and shows the card on the lens.
@MainActor @Observable final class Glasses {
    var status = "Not connected"
    var connected = false
    var connecting = false
    var identifying = false
    var snapshot: UIImage?
    var result: Identification = .ready

    @ObservationIgnored var store: Store?
    /// The last automatic "seen" mark, so correcting a wrong match restores the wrong person's time.
    @ObservationIgnored private var lastMark: (id: String, previous: Date?)?
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var camera: Camera?
    @ObservationIgnored private var display: Display?
    @ObservationIgnored private var displayReady = false
    @ObservationIgnored private var tokens: [any AnyListenerToken] = []
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var photoWaiter: CheckedContinuation<CIImage?, Never>?
    @ObservationIgnored private var frameWaiter: CheckedContinuation<CIImage?, Never>?
    @ObservationIgnored private let worker = DispatchQueue(label: "glasses-faces")

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

            // The stream is never started except as a one-frame fallback; photos come from camera.photo.
            guard let camera = try session.addCamera(config: StreamConfiguration(videoCodec: .raw, resolution: .high, frameRate: 15)) else {
                status = "Glasses camera unavailable"
                return
            }
            tokens.append(camera.photo.photoDataPublisher.listen { [weak self] capture in
                let image = CIImage(data: capture.imageData, options: [.applyOrientationProperty: true])
                Task { @MainActor in self?.resumePhoto(image) }
            })
            tokens.append(camera.photo.errorPublisher.listen { [weak self] error in
                Task { @MainActor in
                    self?.status = error.localizedDescription
                    self?.resumePhoto(nil)
                }
            })
            tokens.append(camera.stream.videoFramePublisher.listen { [weak self] frame in
                guard let image = frame.makeUIImage().flatMap({ CIImage(image: $0) }) else { return }
                Task { @MainActor in self?.resumeFrame(image) }
            })
            camera.photo.start()
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
        display?.stop()
        session?.stop()
        teardown(status: "Not connected")
    }

    func identify() async {
        guard connected, !identifying, let store else { return }
        identifying = true
        renderLens()
        defer {
            identifying = false
            renderLens()
        }

        var image = await capturePhoto()
        if image == nil { image = await grabFrame() }
        guard let image else {
            result = .noFace
            status = "Couldn't get a photo from the glasses"
            return
        }
        snapshot = UIImage(ciImage: image).rendered()
        let faces = await detect(image)
        result = faces.first.map(classify) ?? .noFace
        recordSeen()
    }

    private func recordSeen() {
        guard case .known(let match, _) = result, let store else { return }
        lastMark = (match.person.id, store.markSeen(match.person.id))
    }

    /// Re-match the last face after it was saved to someone.
    func rematch() {
        switch result {
        case .known(_, let face?), .unknown(let face):
            if let lastMark { store?.markSeen(lastMark.id, at: lastMark.previous) }
            result = classify(face)
            recordSeen()
            renderLens()
        default: break
        }
    }

    #if DEBUG
    /// Screenshot hook: PREVIEW_PERSON=<id> shows that person's card without glasses.
    func preview(_ person: Person) {
        result = .known(Match(person: person, score: 1), nil)
        store?.markSeen(person.id)
    }
    #endif

    func dismiss() {
        result = .ready
        renderLens()
    }

    private func classify(_ face: FaceHit) -> Identification {
        guard let store else { return .noFace }
        return store.match(face.embedding).map { .known($0, face) } ?? .unknown(face)
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
        result = .ready
        resumePhoto(nil)
        resumeFrame(nil)
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

    // MARK: - Camera

    private func capturePhoto() async -> CIImage? {
        guard let photo = camera?.photo else { return nil }
        return await withCheckedContinuation { done in
            photoWaiter = done
            photo.capturePhoto(resolution: .medium, quality: .medium)
            Task {
                try? await Task.sleep(for: .seconds(8))
                resumePhoto(nil)
            }
        }
    }

    /// Fallback when photo capture isn't available: run the stream just long enough for one frame.
    private func grabFrame() async -> CIImage? {
        guard let camera else { return nil }
        camera.photo.stop()
        camera.stream.start()
        let frame = await withCheckedContinuation { done in
            frameWaiter = done
            Task {
                try? await Task.sleep(for: .seconds(5))
                resumeFrame(nil)
            }
        }
        camera.stream.stop()
        camera.photo.start()
        return frame
    }

    private func resumePhoto(_ image: CIImage?) {
        photoWaiter?.resume(returning: image)
        photoWaiter = nil
    }

    private func resumeFrame(_ image: CIImage?) {
        frameWaiter?.resume(returning: image)
        frameWaiter = nil
    }

    private func detect(_ image: CIImage) async -> [FaceHit] {
        await withCheckedContinuation { done in
            worker.async { done.resume(returning: FaceEngine.faces(in: image)) }
        }
    }

    // MARK: - Lens

    private func renderLens() {
        guard let display, displayReady else { return }
        let view = identifying ? LensCards.working() : LensCards.card(
            for: result,
            avatar: { [store] in store?.avatars[$0] },
            hasFaces: store?.hasFaces ?? false,
            identify: { [weak self] in Task { @MainActor in await self?.identify() } },
            dismiss: { [weak self] in Task { @MainActor in self?.dismiss() } }
        )
        Task { try? await display.send(view) }
    }
}

private extension UIImage {
    /// CIImage-backed UIImages don't render in SwiftUI reliably; bake to a CGImage.
    func rendered() -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
