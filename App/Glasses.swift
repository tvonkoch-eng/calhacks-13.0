import CoreImage
import MWDATCamera
import MWDATCore
import MWDATDisplay
import MWDATInputs
#if DEBUG
import MWDATMockDevice
#endif
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

/// Meta glasses session. Pressing Identify (lens button, glasses capture button, or the phone)
/// grabs one frame from the glasses camera, matches the largest face, and shows the card on the lens.
/// The camera stream runs only until a usable frame arrives: video on the glasses shares the radio
/// with the lens and the Neural Band, and keeping it up made lens writes take 3-5 s and dropped the band.
@MainActor @Observable final class Glasses {
    var status = "Not connected"
    var connected = false
    var connecting = false
    var identifying = false
    var result: Identification = .ready
    /// Takes over the lens while it is set; the identity card comes back when it clears.
    var answer: AnswerCard?
    /// DEBUG: what simulated Display glasses are showing, when MOCK_GLASSES=1.
    var mockLens: UIView?

    @ObservationIgnored var store: Store?
    /// The last automatic "seen" mark, so correcting a wrong match restores the wrong person's time.
    @ObservationIgnored private var lastMark: (id: String, previous: Date?)?
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var camera: Camera?
    @ObservationIgnored private var display: Display?
    @ObservationIgnored private var displayReady = false
    @ObservationIgnored private var tokens: [any AnyListenerToken] = []
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var frameWaiter: CheckedContinuation<CIImage?, Never>?
    @ObservationIgnored private var frameRequest = UUID()
    @ObservationIgnored private let worker = DispatchQueue(label: "glasses-faces", qos: .userInitiated)
    @ObservationIgnored private var streamLive = false
    /// Set by Disconnect so we don't reconnect behind the user's back.
    @ObservationIgnored private var userDisconnected = false
    @ObservationIgnored private var lastAutoReconnect = Date.distantPast
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    /// Pressing Identify on the glasses while someone is on screen asks first, so a stray pinch
    /// can't wipe the person you're talking to.
    @ObservationIgnored private var confirming = false
    @ObservationIgnored private var confirmTask: Task<Void, Never>?
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
        userDisconnected = false
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
            let finder = AutoDeviceSelector(wearables: wearables)
            status = "Looking for your glasses"
            SpeedLog.record(["event": "connect", "stage": "lookingForGlasses"])
            var found: DeviceIdentifier?
            for await id in finder.activeDeviceStream() {
                if let id { found = id; break }
            }
            guard let found else { return }
            // Seen is not the same as linked: a session started before the link is up never starts.
            while let device = wearables.deviceForIdentifier(found),
                  !(device.linkState == .connected && device.compatibility() == .compatible) {
                if device.compatibility() == .deviceUpdateRequired {
                    status = "Update your glasses in the Meta AI app"
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            // Pin the session to the glasses we found; a fresh auto selector can start empty.
            let selector = SpecificDeviceSelector(device: found)

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
            SpeedLog.record(["event": "connect", "stage": "startingSession"])
            let session = try wearables.createSession(deviceSelector: selector)
            self.session = session
            tokens.append(session.statePublisher.listen { [weak self] state in
                Task { @MainActor in self?.sessionChanged("\(state)", stopped: state == .stopped) }
            })
            // Subscribe before start(): a stream created afterwards can miss the .started transition.
            let states = session.stateStream()
            try session.start()
            for await state in states where state == .started { break }

            // Standalone photo capture failed instantly on every scan (0 bytes in ~20 ms), so frames come
            // from the stream. Medium (504x896) keeps Bluetooth load down; faces at talking distance
            // are still ~150 px.
            guard let camera = try session.addCamera(config: StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 7)) else {
                status = "Glasses camera unavailable"
                return
            }
            tokens.append(camera.stream.videoFramePublisher.listen { [weak self] frame in
                Task { @MainActor in
                    // Only decode frames someone is waiting for.
                    guard let self, self.frameWaiter != nil else { return }
                    self.resumeFrame(frame.makeUIImage().flatMap { CIImage(image: $0) })
                }
            })
            tokens.append(camera.stream.errorPublisher.listen { error in
                let message = error.localizedDescription
                Task { @MainActor in SpeedLog.record(["event": "streamError", "error": message]) }
            })
            self.camera = camera

            if wearables.deviceForIdentifier(found)?.supportsDisplay() == true {
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
            SpeedLog.record(["event": "connected"])
            watchForGlasses()
        } catch {
            SpeedLog.record(["event": "connectError", "error": "\(error)"])
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

    /// The device decides when a session pauses or ends (band hiccups, another app, folding the
    /// glasses). Log every transition; on an unexpected stop, try one reconnect.
    private func sessionChanged(_ state: String, stopped: Bool) {
        SpeedLog.record(["event": "session", "state": state])
        guard stopped, connected else { return }
        teardown(status: "Glasses disconnected")
        reconnectSoon(reason: "sessionStopped")
    }

    /// At most one automatic reconnect every 30 s, so a device that keeps ending the session
    /// can't put us in a loop.
    private func reconnectSoon(reason: String) {
        guard !userDisconnected, Date().timeIntervalSince(lastAutoReconnect) > 30 else { return }
        lastAutoReconnect = Date()
        SpeedLog.record(["event": "reconnect", "reason": reason])
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.connect()
        }
    }

    /// Reconnect when the glasses come back (unfolded, back in range).
    private func watchForGlasses() {
        guard watchTask == nil else { return }
        let finder = AutoDeviceSelector(wearables: Wearables.shared)
        watchTask = Task { [weak self] in
            var available = true
            for await id in finder.activeDeviceStream() {
                guard let self else { return }
                if id != nil, !available, !self.connected, !self.connecting { self.reconnectSoon(reason: "glassesAvailable") }
                available = id != nil
            }
        }
    }

    func disconnect() {
        userDisconnected = true
        display?.stop()
        session?.stop()
        teardown(status: "Not connected")
    }

    /// `source` is only for the speed log: phone, lens, or glasses (capture/action button).
    func identify(source: String = "phone") async {
        guard connected, !identifying, let store else {
            SpeedLog.record(["event": "skipped", "source": source,
                             "reason": !connected ? "notConnected" : identifying ? "busy" : "noStore"])
            return
        }
        let start = CFAbsoluteTimeGetCurrent()
        identifying = true
        var log: [String: Any] = ["source": source, "resolution": "medium-stream"]
        defer {
            identifying = false
            stopStream()
        }
        renderLens()

        // A cold stream's first frames can be dark while exposure settles: give it three frames.
        var scan: (hit: FaceHit?, timing: FaceTiming) = (nil, FaceTiming())
        var frames = 0
        repeat {
            guard let image = await nextFrame() else { break }
            frames += 1
            if frames == 1 {
                log["frameMs"] = ms(since: start)
                log["width"] = Int(image.extent.width)
                log["height"] = Int(image.extent.height)
            }
            scan = await scanLargest(image)
        } while scan.hit == nil && frames < 3
        // Free the radio before talking to the lens.
        stopStream()
        log["frames"] = frames
        log["captureMs"] = ms(since: start)
        guard frames > 0 else {
            result = .noFace
            log["outcome"] = "noImage"
            await finish(&log, start: start)
            return
        }
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
        renderLens()
    }

    /// MOCK_GLASSES=1: pair simulated Ray-Ban Display glasses (registered, permissions granted)
    /// and mirror their lens into the app, so the whole flow runs without hardware.
    func useMockGlasses() {
        MockDeviceKit.shared.enable()
        guard let glasses = try? MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay) else { return }
        glasses.powerOn()
        glasses.don()
        if let photo = Bundle.main.url(forResource: "avi_02", withExtension: "jpg") {
            glasses.services.camera.setCapturedImage(fileURL: photo)
        }
        mockLens = glasses.services.display.createPreviewView()
    }
    #endif

    /// Identify from the glasses (lens button or capture button). With a person on screen the
    /// first press turns the button into "Are you sure?"; a second press within 2 s identifies,
    /// otherwise the person stays.
    func lensIdentify(source: String) async {
        if case .known = result, !confirming {
            confirming = true
            SpeedLog.record(["event": "confirmAsk", "source": source])
            confirmTask?.cancel()
            let hold: Double = source == "preview" ? 600 : 2   // preview: hold for screenshots
            confirmTask = Task { [weak self] in
                // The 2 s starts once "Are you sure?" is actually on the lens, not when it was asked for.
                _ = await self?.sendLens()
                try? await Task.sleep(for: .seconds(hold))
                guard !Task.isCancelled, let self, self.confirming else { return }
                SpeedLog.record(["event": "confirmExpired"])
                self.confirming = false
                self.renderLens()
            }
            return
        }
        confirmTask?.cancel()
        confirming = false
        await identify(source: source)
    }

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
        streamLive = false
        resumeFrame(nil)
        self.status = status
    }

    /// Glasses capture button / action button → identify. Needs Inputs enabled in Wearables Developer Center.
    private func attachInputs(_ session: DeviceSession) {
        // Physical buttons only. Including .neuralBand / .captouch here makes Inputs swallow the band's
        // pinch (haptic, but the lens button never gets the click).
        let configuration = InputsConfiguration(sources: [.captureButton, .actionButton], consumeBack: false)
        guard let inputs = try? session.addInputs(configuration: configuration) else { return }
        let events = inputs.events
        inputTask = Task { [weak self] in
            for await event in events {
                switch event {
                case .capture(.shortPress, _, _), .button(.action, _, _):
                    await self?.lensIdentify(source: "glasses")
                default:
                    break
                }
            }
        }
    }

    // MARK: - Camera

    /// The next frame from the glasses camera, starting the stream if it isn't running.
    private func nextFrame() async -> CIImage? {
        guard let camera else { return nil }
        if !streamLive {
            camera.stream.start()
            streamLive = true
        }
        let request = UUID()
        frameRequest = request
        return await withCheckedContinuation { done in
            frameWaiter = done
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                // Only time out this request, never a later one.
                guard let self, self.frameRequest == request else { return }
                SpeedLog.record(["event": "frameTimeout"])
                self.resumeFrame(nil)
            }
        }
    }

    private func stopStream() {
        guard streamLive else { return }
        camera?.stream.stop()
        streamLive = false
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
        send(hud())
    }

    /// The identity HUD as it stands right now.
    private func hud() -> FlexBox {
        LensCards.hud(
            result: result,
            avatar: { [store] in store?.lensAvatar($0) },
            identifying: identifying,
            confirming: confirming,
            connected: store?.connectedCount ?? 0,
            identify: { [weak self] in Task { @MainActor in await self?.lensIdentify(source: "lens") } }
        )
    }

    /// Rate-limited lens write. The first frame of an answer goes out immediately; the stream of
    /// token updates behind it collapses into one frame every `minSendInterval`, last value wins.
    private func send(_ view: FlexBox) {
        pendingSend?.cancel()
        let wait = minSendInterval - Date().timeIntervalSince(lastSend)
        guard wait > 0 else {
            lastSend = Date()
            Task { await self.write(view) }
            return
        }
        pendingSend = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, let display = self.display else { return }
            self.lastSend = Date()
            _ = display
            await self.write(view)
        }
    }

    private func write(_ view: FlexBox) async {
        guard let display else { return }
        let start = CFAbsoluteTimeGetCurrent()
        do {
            try await display.send(view)
            let elapsed = ms(since: start)
            if elapsed > 1000 { SpeedLog.record(["event": "lensSlow", "ms": elapsed]) }
        } catch {
            SpeedLog.record(["event": "lensError", "error": "\(error)"])
        }
    }

    /// Sends the identity card and waits for it (timed in the speed log); false when there's no
    /// lens or a conversation answer currently owns it.
    private func sendLens() async -> Bool {
        guard let display, displayReady, answer == nil else { return false }
        let view = hud()
        pendingSend?.cancel()
        lastSend = Date()
        do {
            try await display.send(view)
        } catch {
            SpeedLog.record(["event": "lensError", "error": "\(error)"])
            return false
        }
        return true
    }
}

private extension UIImage {
    /// CIImage-backed UIImages don't render in SwiftUI reliably; bake to a CGImage.
    func rendered() -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
