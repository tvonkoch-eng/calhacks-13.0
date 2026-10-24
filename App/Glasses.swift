import AVFoundation
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

/// Meta glasses session. The camera stream runs for the whole session (stopping it is one-way —
/// see face-id-fix), so frames arrive at 5 fps whether or not anyone pressed anything. Two of them
/// a second go through the watch path, which puts a card on the lens by itself for a confident,
/// stable match. Pressing Identify (lens button, glasses capture button, or the phone) still works
/// and overrides the watch: it takes the next frame and accepts the closest person, threshold or not.
@MainActor @Observable final class Glasses {
    var status = "Not connected"
    var connected = false
    var connecting = false
    var identifying = false
    var result: Identification = .ready
    /// Takes over the lens while it is set; the identity card comes back when it clears.
    var answer: AnswerCard?
    /// DEBUG: what simulated Display glasses are showing, in phone-sim mode.
    var mockLens: UIView?
    /// DEBUG: true while the session is running against a simulated pair driven by this phone.
    var mocking = false
    /// DEBUG: the newest frame off the simulated stream — what the "glasses" camera is seeing.
    /// The lens never shows this: the camera is input, the lens is output. In phone-sim mode
    /// you want both on screen, so the panel can aim the phone.
    var pov: UIImage?
    @ObservationIgnored private var lastPov = Date.distantPast
    @ObservationIgnored private var povWatch: Task<Void, Never>?

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
    /// Set when the stream reports an error or wedges; the next frame request rebuilds the camera.
    @ObservationIgnored private var streamBroken = false
    @ObservationIgnored private var cameraTokens: [any AnyListenerToken] = []
    /// Medium (504x896) at 5 fps: faces at talking distance are still ~150 px, and the radio keeps
    /// headroom for lens writes and the Neural Band.
    /// 5 fps is a Bluetooth budget, not a camera limit: video, the lens and the Neural Band share
    /// one radio on a real pair. A simulated pair is a local AVCaptureSession with no radio, so it
    /// can run at a rate that actually looks live.
    private var streamConfig: StreamConfiguration {
        var rate: UInt = 5
        #if DEBUG
        if mocking { rate = 24 }
        #endif
        return StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: rate)
    }
    #if DEBUG
    /// The simulated pair, kept so switching rigs can unpair it cleanly.
    @ObservationIgnored private var mock: (any MockGlasses)?
    #endif
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

    // MARK: Auto-identify
    /// Recognise people straight off the stream, no press. The stream is up for the whole
    /// session anyway (stopping it is one-way), so the frames are already arriving and being
    /// thrown away; this looks at a couple of them a second.
    var watching: Bool = (UserDefaults.standard.object(forKey: "AutoIdentify") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(watching, forKey: "AutoIdentify") }
    }
    /// One watch scan at a time.
    @ObservationIgnored private var autoBusy = false
    @ObservationIgnored private var lastAutoScan = Date.distantPast
    /// 5 fps arrives; look at two of them a second and drop the rest undecoded.
    @ObservationIgnored private let autoInterval: TimeInterval = 0.5
    /// A confident match has to show up twice running before it reaches the lens, so someone
    /// walking past behind your shoulder can't take the card.
    @ObservationIgnored private var pending: (id: String, at: Date)?
    /// When the current card went up, so a stale one stops blocking a new person.
    @ObservationIgnored private var resultAt = Date.distantPast
    /// Don't announce the same person over and over.
    @ObservationIgnored private var lastShown: [String: Date] = [:]
    @ObservationIgnored private let reannounceAfter: TimeInterval = 60
    /// How long a card owns the lens before the watch may replace it.
    @ObservationIgnored private let cardHolds: TimeInterval = 20

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
            guard let camera = try session.addCamera(config: streamConfig) else {
                status = "Glasses camera unavailable"
                return
            }
            attachCamera(camera)
            // Bring the stream up now, not on the first press: spinning it up cost ~830 ms of
            // every identify, and it is the single biggest item on the clock.
            startStream()

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
            #if DEBUG
            if mocking {
                lastPov = Date()
                watchMockFrames()
            }
            #endif
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
        pending = nil
        var log: [String: Any] = ["source": source, "resolution": "medium-stream"]
        defer { identifying = false }
        renderLens()

        // A cold stream's first frames can be dark while exposure settles: give it three frames.
        var hits: [FaceHit] = []
        var timing = FaceTiming()
        var frames = 0
        repeat {
            guard let image = await nextFrame() else { break }
            frames += 1
            if frames == 1 {
                log["frameMs"] = ms(since: start)
                log["width"] = Int(image.extent.width)
                log["height"] = Int(image.extent.height)
            }
            let scan = await scanFaces(image)
            hits = scan.hits
            timing = scan.timing
        } while hits.isEmpty && frames < 3
        log["frames"] = frames
        log["captureMs"] = ms(since: start)
        guard frames > 0 else {
            result = .noFace
            log["outcome"] = "noImage"
            await finish(&log, start: start)
            return
        }
        log["detectMs"] = (timing.detectMs * 10).rounded() / 10
        log["embedMs"] = (timing.embedMs * 10).rounded() / 10
        log["faces"] = timing.faces
        log["embedded"] = hits.count

        let matchStart = CFAbsoluteTimeGetCurrent()
        // Everyone in the frame is a candidate. The person you just turned to is not reliably the
        // biggest face, and matching the largest one only ever identified a single person.
        let pick = bestKnown(hits)
        if let pick {
            result = pick.match.map { .known($0, pick.hit) } ?? .unknown(pick.hit)
        } else {
            result = .noFace
        }
        recordSeen()
        log["matchMs"] = ms(since: matchStart)
        if let hit = pick?.hit {
            let ranked = store.ranked(hit.embedding)
            log["person"] = ranked.first?.person.id
            log["score"] = ranked.first.map { (Double($0.score) * 1000).rounded() / 1000 }
            log["runnerUp"] = ranked.dropFirst().first.map { (Double($0.score) * 1000).rounded() / 1000 }
        }
        log["outcome"] = pick == nil ? "noFace" : "known"
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
        // Shared with the watch path: a press counts as showing this person too, so auto doesn't
        // immediately re-announce whoever you just identified by hand.
        resultAt = Date()
        lastShown[match.person.id] = Date()
        pending = nil
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
    func useMockGlasses() async {
        MockDeviceKit.shared.enable()
        guard let glasses = try? MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay) else { return }
        mock = glasses
        mocking = true
        glasses.powerOn()
        // A pair only appears in Wearables' device stream once it is powered on AND unfolded;
        // without this connect() waits on activeDeviceStream() forever.
        glasses.unfold()
        glasses.don()
        // Our identify path reads frames from camera.stream, not capturePhoto, and the kit
        // refuses — fatally — to stream from a pair whose feed was never set. Point the mock
        // camera at the phone's own camera: held up, the phone sees roughly what the wearer
        // would, so face identification runs end to end with no glasses in the room.
        // MOCK_CAMERA=front to use the selfie camera instead.
        //
        // That feed is an AVCaptureSession on this phone, so it needs the app's own iOS camera
        // grant — which nothing else here ever asks for, because the real glasses send frames
        // over Bluetooth and their permission is Meta's, not Apple's. Ungranted, the mock
        // streams black frames forever and never errors.
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            status = "Allow camera access in Settings to use the phone simulator"
            SpeedLog.record(["event": "mockCameraDenied"])
        }
        let facing: CameraFacing = ProcessInfo.processInfo.environment["MOCK_CAMERA"] == "front" ? .front : .back
        // Set the feed even when denied: the kit crashes fatally on a stream with no feed at all.
        glasses.services.camera.setCameraFeed(cameraFacing: facing)
        if let photo = Bundle.main.url(forResource: "avi_02", withExtension: "jpg") {
            glasses.services.camera.setCapturedImage(fileURL: photo)
        }
        mockLens = glasses.services.display.createPreviewView()
    }

    /// The simulated stream stops delivering without ever erroring — the kit's capture session
    /// gets interrupted (arming the mic is one way) and nothing tells us. A real pair would have
    /// raised a stream error. So watch the POV clock and poke the stream back to life.
    private func watchMockFrames() {
        povWatch?.cancel()
        povWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(800))
                guard let self, self.mocking, self.connected, let camera = self.camera else { return }
                guard Date().timeIntervalSince(self.lastPov) > 1.5 else { continue }
                camera.stream.start()
                self.streamLive = true
                self.lastPov = Date()
            }
        }
    }

    /// Which rig to come up on, remembered across launches. `MOCK_GLASSES=1` / `=0` still wins
    /// when Xcode or devicectl sets it, but tapping the icon on the phone has no environment at
    /// all — so the stored toggle is what makes the choice survive a plain launch.
    static var prefersMock: Bool {
        switch ProcessInfo.processInfo.environment["MOCK_GLASSES"] {
        case "1": return true
        case "0": return false
        default: return UserDefaults.standard.bool(forKey: mockKey)
        }
    }

    static let mockKey = "MockGlasses"

    /// Swap rigs live, no rebuild: drop the session, change the kit under it, come back up.
    /// Reconnecting is not optional — the session is pinned to one device identifier, and the
    /// simulated pair is a different device than the real one.
    func useMock(_ on: Bool) async {
        guard on != mocking else { return }
        UserDefaults.standard.set(on, forKey: Self.mockKey)
        disconnect()
        mockLens = nil
        if on {
            await useMockGlasses()
        } else {
            if let mock { await MockDeviceKit.shared.unpairDevice(mock) }
            mock = nil
            await MockDeviceKit.shared.disable()
            mocking = false
        }
        // disconnect() set the "user meant it" flag; this switch is a reconnect, not a stop.
        userDisconnected = false
        status = on ? "Starting phone simulator…" : "Looking for your glasses"
        await connect()
    }
    #endif

    /// Identify from the glasses (lens button or capture button). With a person on screen the
    /// first press turns the button into "Are you sure?"; a second press within 2 s identifies,
    /// otherwise the person stays.
    func lensIdentify(source: String) async {
        // No "Are you sure?" step. It cost a second press and a 2 s wait for every person after
        // the first, which is most of what made meeting a second person feel broken.
        confirmTask?.cancel()
        confirming = false
        await identify(source: source)
    }

    func dismiss() {
        result = .ready
        resultAt = .distantPast
        pending = nil
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
        releaseCameraTokens()
        streamBroken = false
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
        #if DEBUG
        povWatch?.cancel()
        povWatch = nil
        pov = nil
        #endif
        autoBusy = false
        pending = nil
        resultAt = .distantPast
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
        if let image = await frame() { return image }
        // Wedged. Rebuild the camera off the session and give it one more go.
        streamBroken = true
        return await frame()
    }

    private func frame() async -> CIImage? {
        if streamBroken || camera == nil { rebuildCamera() }
        guard camera != nil else { return nil }
        startStream()
        let request = UUID()
        frameRequest = request
        return await withCheckedContinuation { done in
            frameWaiter = done
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                // Only time out this request, never a later one.
                guard let self, self.frameRequest == request else { return }
                SpeedLog.record(["event": "frameTimeout"])
                self.resumeFrame(nil)
            }
        }
    }

    private func startStream() {
        guard let camera, !streamLive else { return }
        camera.stream.start()
        streamLive = true
    }

    /// Replaces the camera after a stream error. Stopping a stream is one-way: the SDK answers a
    /// later start() with "Critical error, the stream should end" and never sends another frame,
    /// which is why every identify after the first one used to time out. Recovery is a fresh
    /// addCamera on the same session, not a reconnect.
    private func rebuildCamera() {
        guard let session else { return }
        SpeedLog.record(["event": "cameraRebuild"])
        camera?.stop()
        releaseCameraTokens()
        camera = nil
        streamLive = false
        streamBroken = false
        guard let fresh = (try? session.addCamera(config: streamConfig)) ?? nil else {
            SpeedLog.record(["event": "cameraRebuildFailed"])
            return
        }
        attachCamera(fresh)
    }

    private func attachCamera(_ camera: Camera) {
        cameraTokens.append(camera.stream.videoFramePublisher.listen { [weak self] frame in
            // Decode on the publisher's own thread. Hopping to the main actor first and calling
            // makeUIImage() there is what made the POV tile stutter: the decode was spending the
            // UI's frame budget. The main actor only ever receives finished images.
            let image = frame.makeUIImage()
            let small = image?.fitted(to: 360)
            Task { @MainActor in
                guard let self else { return }
                #if DEBUG
                if let small, Date().timeIntervalSince(self.lastPov) > 0.04 {
                    self.lastPov = Date()
                    self.pov = small
                }
                #endif
                // A press parked on a continuation always wins the frame.
                if self.frameWaiter != nil {
                    self.resumeFrame(image.flatMap { CIImage(image: $0) })
                    return
                }
                // Otherwise the watch gets a look, at its own throttled cadence.
                guard self.claimAutoScan() else { return }
                guard let ci = image.flatMap({ CIImage(image: $0) }) else {
                    self.autoBusy = false
                    return
                }
                await self.autoScan(ci)
            }
        })
        cameraTokens.append(camera.stream.errorPublisher.listen { [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor in
                SpeedLog.record(["event": "streamError", "error": message])
                self?.streamBroken = true
            }
        })
        self.camera = camera
    }

    private func releaseCameraTokens() {
        let stale = cameraTokens
        cameraTokens = []
        Task { for token in stale { await token.cancel() } }
    }

    private func resumeFrame(_ image: CIImage?) {
        frameWaiter?.resume(returning: image)
        frameWaiter = nil
    }

    // MARK: - Auto-identify

    /// True when a watch scan should run on this frame, and claims the slot if so.
    private func claimAutoScan() -> Bool {
        guard watching, connected, !identifying, !autoBusy, store != nil else { return false }
        // A live conversation answer owns the lens; never fight it for the frame.
        guard answer == nil else { return false }
        // Someone is already on the card. Leave them there for a bit, then allow a new person.
        if case .known = result, Date().timeIntervalSince(resultAt) < cardHolds { return false }
        guard Date().timeIntervalSince(lastAutoScan) >= autoInterval else { return false }
        autoBusy = true
        lastAutoScan = Date()
        return true
    }

    /// Scan a watch frame. Quiet by design: this path only ever writes the lens for a confident,
    /// stable, not-just-shown match. A miss leaves whatever is on the lens exactly as it was —
    /// no "No face found" appearing while nobody asked for anything.
    private func autoScan(_ image: CIImage) async {
        defer { autoBusy = false }
        let start = CFAbsoluteTimeGetCurrent()
        let scan = await scanFaces(image)
        guard let store, !scan.hits.isEmpty else { pending = nil; return }

        var best: (hit: FaceHit, match: Match)?
        for hit in scan.hits {
            guard let match = store.confidentMatch(hit.embedding) else { continue }
            if let current = best, match.score <= current.match.score { continue }
            best = (hit, match)
        }
        guard let best else { pending = nil; return }

        // Two consecutive scans (~0.5 s apart) on the same person before we commit.
        let person = best.match.person.id
        guard let seen = pending, seen.id == person, Date().timeIntervalSince(seen.at) < 2 else {
            pending = (person, Date())
            return
        }
        pending = nil
        if let last = lastShown[person], Date().timeIntervalSince(last) < reannounceAfter { return }
        // Re-check: a press or an answer may have taken the lens while we were embedding.
        guard answer == nil, !identifying else { return }

        result = .known(best.match, best.hit)
        recordSeen()
        var log: [String: Any] = ["event": "autoIdentify", "source": "watch",
                                  "person": person,
                                  "score": (Double(best.match.score) * 1000).rounded() / 1000,
                                  "faces": scan.timing.faces, "embedded": scan.hits.count,
                                  "detectMs": (scan.timing.detectMs * 10).rounded() / 10,
                                  "embedMs": (scan.timing.embedMs * 10).rounded() / 10,
                                  "scanMs": ms(since: start)]
        log["runnerUp"] = store.ranked(best.hit.embedding).dropFirst().first
            .map { (Double($0.score) * 1000).rounded() / 1000 }
        let lensStart = CFAbsoluteTimeGetCurrent()
        if await sendLens() { log["lensMs"] = ms(since: lensStart) }
        log["totalMs"] = ms(since: start)
        SpeedLog.record(log)
    }

    /// Detect every face, embed the four largest. An embedding is ~8 ms, so the extra candidates
    /// are nearly free, and they are what makes a second person in the frame matchable at all.
    private func scanFaces(_ image: CIImage) async -> (hits: [FaceHit], timing: FaceTiming) {
        await withCheckedContinuation { done in
            worker.async {
                done.resume(returning: FaceEngine.scan(image, limit: 4))
            }
        }
    }

    /// The face in this frame with the strongest match; when nobody is known, the largest face.
    private func bestKnown(_ hits: [FaceHit]) -> (hit: FaceHit, match: Match?)? {
        guard let store, let largest = hits.first else { return nil }
        var best: (hit: FaceHit, match: Match)?
        for hit in hits {
            guard let match = store.match(hit.embedding) else { continue }
            if let current = best, match.score <= current.match.score { continue }
            best = (hit, match)
        }
        if let best { return (best.hit, best.match) }
        return (largest, nil)
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

extension UIImage {
    /// A copy no larger than `max` on its long side. The POV tile is ~180 pt wide; handing
    /// SwiftUI a full 480x640 image every frame is wasted texture upload.
    func fitted(to max: CGFloat) -> UIImage {
        let longest = Swift.max(size.width, size.height)
        guard longest > max, longest > 0 else { return self }
        let scale = max / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

private extension UIImage {
    /// CIImage-backed UIImages don't render in SwiftUI reliably; bake to a CGImage.
    func rendered() -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
