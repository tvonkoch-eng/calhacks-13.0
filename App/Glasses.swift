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
    case known(Match, FaceHit?)
}

/// Meta glasses session. Nothing streams: pressing Identify (lens button, glasses capture
/// button, or the phone) takes one photo, matches the largest face, and shows the card on the lens.
@MainActor @Observable final class Glasses {
    var status = "Not connected"
    var connected = false
    var connecting = false
    var identifying = false
    var result: Identification = .ready
    /// Takes over the lens while it is set; the identity card comes back when it clears.
    var answer: AnswerCard?

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
    @ObservationIgnored private let worker = DispatchQueue(label: "glasses-faces", qos: .userInitiated)
    @ObservationIgnored private var photoBytes = 0
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
            // Find the glasses first: asking for permissions with no glasses nearby just throws noDevice.
            let selector = AutoDeviceSelector(wearables: wearables)
            status = "Looking for your glasses"
            for await id in selector.activeDeviceStream() {
                if id != nil { break }
            }

            do throws(PermissionError) {
                if try await wearables.checkPermissionStatus(.camera) != .granted {
                    status = "Allow camera access in Meta AI"
                    guard try await wearables.requestPermission(.camera) == .granted else {
                        status = "Camera access was denied in Meta AI"
                        return
                    }
                }
            } catch {
                status = Self.message(for: error)
                return
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
                let bytes = capture.imageData.count
                Task { @MainActor in
                    self?.photoBytes = bytes
                    self?.resumePhoto(image)
                }
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
            status = (error as? LocalizedError)?.errorDescription ?? "Couldn't connect to your glasses. Try again."
        }
    }

    /// Plain-language versions of the SDK's permission errors.
    private static func message(for error: PermissionError) -> String {
        switch error {
        case .noDevice, .noDeviceWithConnection, .connectionError:
            "Turn on your glasses and keep them near your phone"
        case .metaAINotInstalled:
            "Install the Meta AI app to connect your glasses"
        case .requestInProgress:
            "Finish the request in the Meta AI app"
        case .requestTimeout:
            "Meta AI didn't respond. Try again."
        case .internalError:
            "Couldn't reach your glasses. Try again."
        @unknown default:
            "Couldn't reach your glasses. Try again."
        }
    }

    func disconnect() {
        display?.stop()
        session?.stop()
        teardown(status: "Not connected")
    }

    /// `source` is only for the speed log: phone, lens, or glasses (capture/action button).
    func identify(source: String = "phone") async {
        guard connected, !identifying, let store else { return }
        let start = CFAbsoluteTimeGetCurrent()
        identifying = true
        var log: [String: Any] = ["source": source, "resolution": photoResolution.rawValue, "quality": photoQuality.rawValue]
        defer { identifying = false }

        async let capturing = capturePhoto()
        renderLens()
        var image = await capturing
        log["captureMs"] = ms(since: start)
        log["path"] = "photo"
        log["bytes"] = photoBytes
        if image == nil {
            let fallback = CFAbsoluteTimeGetCurrent()
            image = await grabFrame()
            log["path"] = "frame"
            log["fallbackMs"] = ms(since: fallback)
        }
        guard let image else {
            result = .noFace
            log["outcome"] = "noImage"
            await finish(&log, start: start)
            return
        }
        log["width"] = Int(image.extent.width)
        log["height"] = Int(image.extent.height)

        let scan = await scanLargest(image)
        log["detectMs"] = (scan.timing.detectMs * 10).rounded() / 10
        log["embedMs"] = (scan.timing.embedMs * 10).rounded() / 10
        log["faces"] = scan.timing.faces

        let matchStart = CFAbsoluteTimeGetCurrent()
        result = scan.hit.map(classify) ?? .noFace
        recordSeen()
        log["matchMs"] = ms(since: matchStart)
        if let hit = scan.hit {
            let ranked = store.ranked(hit.embedding)
            log["person"] = ranked.first?.person.id
            log["score"] = ranked.first.map { (Double($0.score) * 1000).rounded() / 1000 }
            log["runnerUp"] = ranked.dropFirst().first.map { (Double($0.score) * 1000).rounded() / 1000 }
        }
        log["outcome"] = scan.hit == nil ? "noFace" : "known"
        await finish(&log, start: start)
    }

    /// Time to answer = when the phone shows the result; the lens send is timed separately.
    private func finish(_ log: inout [String: Any], start: CFAbsoluteTime) async {
        log["toResultMs"] = ms(since: start)
        identifying = false
        let lensStart = CFAbsoluteTimeGetCurrent()
        if await sendLens() { log["lensMs"] = ms(since: lensStart) }
        log["totalMs"] = ms(since: start)
        SpeedLog.record(log)
    }

    /// Photo size is tunable without a rebuild: launch with `-photoResolution small -photoQuality low`.
    private var photoResolution: PhotoResolution {
        UserDefaults.standard.string(forKey: "photoResolution").flatMap(PhotoResolution.init(rawValue:)) ?? .medium
    }

    private var photoQuality: PhotoQuality {
        UserDefaults.standard.string(forKey: "photoQuality").flatMap(PhotoQuality.init(rawValue:)) ?? .medium
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

    /// Put a conversation answer on the lens, or clear it and fall back to the identity card.
    func showAnswer(_ card: AnswerCard?) {
        guard card != answer else { return }
        answer = card
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
        pendingSend?.cancel()
        pendingSend = nil
        answer = nil
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
                    await self?.identify(source: "glasses")
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
            photoBytes = 0
            photo.capturePhoto(resolution: photoResolution, quality: photoQuality)
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

    private func scanLargest(_ image: CIImage) async -> (hit: FaceHit?, timing: FaceTiming) {
        await withCheckedContinuation { done in
            worker.async {
                let scan = FaceEngine.scan(image, limit: 1)
                done.resume(returning: (scan.hits.first, scan.timing))
            }
        }
    }

    // MARK: - Lens

    private func renderLens() {
        guard displayReady else { return }
        // A live answer owns the lens. It is the thing the wearer needs in the next half second.
        if let card = answer {
            send(LensCards.answer(card))
            return
        }
        let view = identifying ? LensCards.working() : LensCards.card(
            for: result,
            avatar: { [store] in store?.avatars[$0] },
            hasFaces: store?.hasFaces ?? false,
            identify: { [weak self] in Task { @MainActor in await self?.identify(source: "lens") } },
            dismiss: { [weak self] in Task { @MainActor in self?.dismiss() } }
        )
        send(view)
    }

    /// Rate-limited lens write. The first frame of an answer goes out immediately; the stream of
    /// token updates behind it collapses into one frame every `minSendInterval`, last value wins.
    private func send(_ view: FlexBox) {
        pendingSend?.cancel()
        let wait = minSendInterval - Date().timeIntervalSince(lastSend)
        guard wait > 0 else {
            lastSend = Date()
            Task { try? await display?.send(view) }
            return
        }
        pendingSend = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, let display = self.display else { return }
            self.lastSend = Date()
            try? await display.send(view)
        }
    }

    /// Sends the identity card and waits for it (timed in the speed log); false when there's no
    /// lens or a conversation answer currently owns it.
    private func sendLens() async -> Bool {
        guard let display, displayReady, answer == nil else { return false }
        let view = LensCards.card(
            for: result,
            avatar: { [store] in store?.avatars[$0] },
            hasFaces: store?.hasFaces ?? false,
            identify: { [weak self] in Task { @MainActor in await self?.identify(source: "lens") } },
            dismiss: { [weak self] in Task { @MainActor in self?.dismiss() } }
        )
        pendingSend?.cancel()
        lastSend = Date()
        do { try await display.send(view) } catch { return false }
        return true
    }
}

private extension UIImage {
    /// CIImage-backed UIImages don't render in SwiftUI reliably; bake to a CGImage.
    func rendered() -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
