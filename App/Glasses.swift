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

/// Hands the glasses' audio buffers to whoever listens, from the SDK's callback thread.
final class AudioSink: @unchecked Sendable {
    var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?
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
    /// What the conversation aid wants on the lens (App/Lens.swift). Who actually gets the lens,
    /// the aid or the face side, is `LensPolicy`.
    private(set) var aidLens = LensView()
    /// The mic is on: the lens leans toward the aid, and a read person card shrinks to one line.
    var aidArmed = false {
        didSet { if aidArmed != oldValue { renderLens() } }
    }
    /// Which way the last lens write went, for the speed log and the phone.
    private(set) var lensMode: LensMode = .identity
    /// The content of the last card handed to the lens, so the phone can mirror it live. Nil when
    /// there is no display to write to. A real pair cannot be read back; this is recorded as the
    /// card is built, which is as close to the truth as the SDK allows.
    var lensShot: LensShot?
    /// DEBUG: what simulated Display glasses are showing, in phone-sim mode.
    var mockLens: UIView?
    /// DEBUG: true while the session is running against a simulated pair driven by this phone.
    var mocking = false
    /// The newest frame off the stream — what the glasses camera is seeing, real or simulated.
    /// The lens never shows this: the camera is input, the lens is output. The phone shows both,
    /// so the wearer's view and the wearer's display can be watched while a session runs.
    var pov: UIImage?
    @ObservationIgnored private var lastPov = Date.distantPast
    /// Frame sizes and arrival times since the camera was attached. Resolution and frame rate are
    /// *requests*: the SDK's bandwidth governor quietly degrades both when the radio is loaded, so
    /// the only honest answer to "what resolution are we getting" is to measure the frames.
    @ObservationIgnored private var frameSizes: [String: Int] = [:]
    @ObservationIgnored private var statsFrom = Date()
    @ObservationIgnored private var statsFrames = 0
    @ObservationIgnored private var sharpSamples: [Float] = []
    @ObservationIgnored private var lastStats = Date.distantPast
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
    /// When the current camera's stream was started, so its first frame gets `firstFrameGrace`.
    @ObservationIgnored private var streamStartedAt = Date.distantPast
    /// The SDK's own word on the stream (streaming / paused / waitingForDevice …), for the watchdog
    /// and the phone. Paused is the glasses' decision (folded, off your face, too hot), not a fault.
    private(set) var streamState = "none"
    @ObservationIgnored private var cameraTokens: [any AnyListenerToken] = []
    /// Medium (504x896) at 5 fps: faces at talking distance are still ~150 px, and the radio keeps
    /// headroom for lens writes and the Neural Band.
    /// 5 fps is a Bluetooth budget, not a camera limit: video, the lens and the Neural Band share
    /// one radio on a real pair. A simulated pair is a local AVCaptureSession with no radio, so it
    /// can run at a rate that actually looks live.
    /// Video, the lens and the Neural Band share one Bluetooth radio, and the link was losing:
    /// a lens write took 4.9 s and the stream wedged into a rebuild loop it never left.
    ///
    /// Two things were wrong. The rate was **5 fps, which is not a value the SDK accepts** — the
    /// documented set is 2, 7, 15, 24, 30. And medium at that rate left no headroom, so the SDK's
    /// own bandwidth governor was degrading quality underneath us. Low is 360x640: a face at
    /// talking distance is still ~105 px, well above the 40 px crop floor, and feature prints
    /// score 0.79 on half-size crops. Both knobs are UserDefaults so they move with no rebuild:
    /// `streamFps` (2/7/15/24/30) and `streamRes` ("low"/"medium"/"high").
    ///
    /// Default is now medium at 2 fps (Toby's call, for battery). That is 0.9 Mpx/s against the
    /// 1.6 Mpx/s of low at 7, so the radio carries less while each face is ~1.4x bigger, which is
    /// what detection and alignment were short of: at low a face was found in only 30-70% of frames.
    /// What the currently-attached camera was actually built with, so a pushed change to
    /// `streamRes`/`streamFps` can notice it needs a new camera. The SDK fixes resolution and
    /// frame rate at addCamera time; changing the defaults alone does nothing until then.
    @ObservationIgnored private var liveStreamSettings: String?
    private var streamSettings: String { "\(Tuning.int("streamFps", 2))/\(UserDefaults.standard.string(forKey: "streamRes") ?? "medium")" }

    private var streamConfig: StreamConfiguration {
        #if DEBUG
        // A simulated pair is a local AVCaptureSession with no radio at all.
        if mocking { return StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 24) }
        #endif
        let fps = UInt(Tuning.int("streamFps", 2))
        let resolution: StreamingResolution = switch UserDefaults.standard.string(forKey: "streamRes") ?? "medium" {
        case "high": .high
        case "low": .low
        default: .medium
        }
        // The glasses' mic rides the camera stream (SDK 1.0.1, experimental): 16 kHz mono PCM,
        // no Bluetooth hands-free route, so iOS's audio is never touched.
        let audio: MWDATCamera.AudioCodec? = streamAudio ? .pcm(sampleRate: .rate16000, numberOfChannels: 1) : nil
        return StreamConfiguration(videoCodec: .raw, audioCodec: audio, resolution: resolution, frameRate: fps)
    }

    /// Ask the stream for the glasses' mic too. Fixed when the camera is added, so a change
    /// restarts the session (~2 s).
    var streamAudio = UserDefaults.standard.string(forKey: "mic") == "glasses"
    /// Where the glasses' audio goes. Called on the SDK's thread.
    @ObservationIgnored let audioSink = AudioSink()
    @ObservationIgnored private var audioFrames = 0

    /// Called when the glasses' audio can't be had (no permission, or streams with audio keep
    /// dying): back to video only, so the camera keeps working, and the phone mic takes over.
    @ObservationIgnored var onStreamAudioLost: ((String) -> Void)?
    /// Streams with audio that died before their first frame, in a row.
    @ObservationIgnored private var audioStreamFailures = 0

    private func disableStreamAudio(reason: String) {
        guard streamAudio else { return }
        streamAudio = false
        audioStreamFailures = 0
        SpeedLog.record(["event": "streamAudioDisabled", "reason": reason])
        onStreamAudioLost?(reason)
    }

    func setStreamAudio(_ on: Bool) {
        guard on != streamAudio else { return }
        streamAudio = on
        audioStreamFailures = 0
        SpeedLog.record(["event": "streamAudio", "on": on])
        if connected { Task { await restartSession() } }
    }
    #if DEBUG
    /// The simulated pair, kept so switching rigs can unpair it cleanly.
    @ObservationIgnored private var mock: (any MockGlasses)?
    #endif
    /// Set by Disconnect so we don't reconnect behind the user's back.
    @ObservationIgnored private var userDisconnected = false
    /// One pending recovery at a time, retried with backoff for as long as it takes. A recovery is
    /// never dropped: the old 20/30 s rate limits returned without doing anything, and that is the
    /// state the app got stuck in ("Waiting for frames" with no camera and nothing scheduled).
    @ObservationIgnored private var recoveryTask: Task<Void, Never>? {
        didSet { recovering = recoveryTask != nil }
    }
    private(set) var recovering = false
    /// Why the camera tile has no picture, for the phone.
    var cameraNote: String {
        if !connected { return recovering || connecting ? "Reconnecting to your glasses…" : status }
        if recovering { return "Camera stalled, reconnecting…" }
        if streamState == "paused" { return "Glasses paused the camera (folded or off your face)" }
        if streamState == "waitingForDevice" { return "Waiting for the glasses…" }
        return "Starting camera…"
    }
    @ObservationIgnored private var recoveryAttempt = 0
    /// Set while only the wearer can fix it (approve in Meta AI, grant camera, update the glasses):
    /// retrying then would open Meta AI every 30 s. Cleared on the next connect.
    @ObservationIgnored private var blockedOnUser = false
    /// The camera restart is tried once per stall; if frames don't come back, the session goes.
    @ObservationIgnored private var cameraRestartTried = false
    /// When a frame last actually arrived. The watchdog below is the only thing that notices a
    /// stream that has gone quiet without erroring — the watch path has no timeout of its own.
    @ObservationIgnored private var lastFrameAt = Date.distantPast
    @ObservationIgnored private var frameWatchdog: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    /// Pressing Identify on the glasses while someone is on screen asks first, so a stray pinch
    /// can't wipe the person you're talking to.
    @ObservationIgnored private var confirming = false
    @ObservationIgnored private var confirmTask: Task<Void, Never>?
    @ObservationIgnored private var lastSend = Date.distantPast
    /// Lens writes go out one at a time, newest wins. Overlapping sends made the display answer
    /// "Superseded by new display request" (13 times in one session) and loaded the shared radio.
    @ObservationIgnored private var queuedView: FlexBox?
    @ObservationIgnored private var lensWriter: Task<Void, Never>?
    @ObservationIgnored private var writeWaiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var lastWriteOK = false
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
    /// Look at every frame we can. A scan is ~8 ms of detection plus ~6 ms per sharp face, and
    /// frames arrive at 7 fps, so the budget is not the constraint — evidence is. Each extra look
    /// at the same face is another vote in the fused embedding.
    @ObservationIgnored private var autoInterval: TimeInterval { TimeInterval(Tuning.float("autoInterval", 0.12)) }
    /// Faces followed across frames, with their embeddings accumulating. This replaces the old
    /// "two consecutive confident frames, reset on any miss" rule, which discarded every near-miss.
    @ObservationIgnored private let tracker = FaceTracker()
    /// How much accumulated evidence a track needs before it may claim the lens. Weight is the
    /// decayed count of sharp looks, so 1.6 is roughly two good frames or three mediocre ones.
    @ObservationIgnored private var minEvidence: Float { Tuning.float("minEvidence", 1.6) }
    /// Tracks that have already had their turn on the lens, so a held card doesn't re-fire.
    @ObservationIgnored private var announced: Set<Int> = []
    /// When the current card went up, so a stale one stops blocking a new person.
    @ObservationIgnored private var resultAt = Date.distantPast
    /// Don't announce the same person over and over.
    @ObservationIgnored private var lastShown: [String: Date] = [:]
    /// Conversation memory. Once someone has been on the lens they are "in the conversation", and
    /// glancing back at them stays quiet for as long as they keep being seen. Only after they have
    /// been out of view for `absentFor` does the next sighting announce them again. In a
    /// three-person conversation that means each person is named once, not on every head turn.
    @ObservationIgnored private var absentFor: TimeInterval { TimeInterval(Tuning.float("absentFor", 180)) }
    /// Last confident sighting per person, shown or not.
    @ObservationIgnored private var sighted: [String: Date] = [:]
    /// Who the wearer is looking at right now (largest confident face in the latest frame), and
    /// everyone confidently seen in the last few seconds. Updated quietly, without touching the
    /// lens, so speech can attribute a voice to a face later.
    private(set) var facing: String? {
        didSet {
            guard facing != oldValue else { return }
            onFacing?(facing)
            // Turning to or away from the person on the card can move the lens between the aid
            // alone and the aid with who you're talking to; write only if it actually moves.
            if aidArmed, currentMode() != lensMode { renderLens() }
        }
    }
    /// Called on the main actor when the person in focus changes (nil = nobody known in view).
    /// For code that isn't SwiftUI, e.g. the conversation aid's "who is THEM" profile.
    @ObservationIgnored var onFacing: ((String?) -> Void)?
    var present: [String] {
        let now = Date()
        return sighted.filter { now.timeIntervalSince($0.value) < 10 }.map(\.key)
    }
    /// How long a card owns the lens before the watch may replace it with someone else. Was 20 s,
    /// which on the glasses meant a 21 s wait to switch from Avi to the next person.
    @ObservationIgnored private var cardHolds: TimeInterval { TimeInterval(Tuning.float("cardHolds", 3)) }
    /// How long a fresh identification owns the whole lens, over any aid card, before the aid may
    /// take it back. Long enough to read a name, a headline and three lines.
    @ObservationIgnored private var bioHolds: TimeInterval { TimeInterval(Tuning.float("bioHolds", 10)) }
    @ObservationIgnored private var bioTask: Task<Void, Never>?
    /// A single look this confident is enough on its own: ArcFace puts the same person at ~0.6-0.7
    /// on a sharp frame and everyone else near 0.
    @ObservationIgnored private var strongScore: Float { Tuning.float("strongScore", 0.55) }
    /// Only the face you are looking at may take the lens: the most attended face in the frame,
    /// or one within this share of it (two people side by side, both facing you). People at the
    /// edge of the view are still recognised and tracked as present, just not announced.
    @ObservationIgnored private var focusShare: Float { Tuning.float("focusShare", 0.7) }

    /// False when the Meta SDK could not start at all — notably in the Simulator, where
    /// `Wearables.configure()` fails and every later touch of `Wearables.shared` traps. Guarding
    /// on it keeps the app itself runnable (and screenshottable) with no glasses stack.
    private(set) static var ready = false

    static func configure() {
        do {
            try Wearables.configure()
            ready = true
        } catch {
            print("Wearables.configure failed: \(error)")
        }
    }

    /// Meta AI calls back here after registration / permission; carry on connecting.
    func handle(_ url: URL) {
        guard Self.ready, URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(where: { $0.name == "metaWearablesAction" }) == true else { return }
        Task {
            _ = try? await Wearables.shared.handleUrl(url)
            await connect()
        }
    }

    func connectIfRegistered() async {
        guard Self.ready else { return }
        if Wearables.shared.registrationState == .registered { await connect() }
    }

    func connect() async {
        guard Self.ready else { status = "Glasses SDK unavailable here"; return }
        guard !connected, !connecting else { return }
        userDisconnected = false
        blockedOnUser = false
        connecting = true
        defer { connecting = false }
        let wearables = Wearables.shared
        do {
            if wearables.registrationState != .registered {
                status = "Approve in Meta AI…"
                blockedOnUser = true
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
                    blockedOnUser = true
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            // Pin the session to the glasses we found; a fresh auto selector can start empty.
            let selector = SpecificDeviceSelector(device: found)

            do throws(PermissionError) {
                // The glasses' mic on the stream needs its own grant; without it every stream
                // that asks for audio dies on its first frame (18:09, five times in a row).
                if streamAudio, try await wearables.checkPermissionStatus(.microphone) != .granted {
                    status = "Allow microphone access in Meta AI"
                    if try await wearables.requestPermission(.microphone) != .granted {
                        disableStreamAudio(reason: "micPermissionDenied")
                    }
                }
                if try await wearables.checkPermissionStatus(.camera) != .granted {
                    status = "Allow camera access in Meta AI"
                    guard try await wearables.requestPermission(.camera) == .granted else {
                        status = "Camera access was denied in Meta AI"
                        blockedOnUser = true
                        return
                    }
                }
            } catch {
                status = Self.message(for: error)
                // No glasses nearby is worth retrying; anything else needs the wearer.
                switch error {
                case .noDevice, .noDeviceWithConnection, .connectionError, .requestTimeout, .internalError: break
                default: blockedOnUser = true
                }
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
            // Never wait forever on .started: a session that doesn't start in 10 s is retried.
            let started = await withTaskGroup(of: Bool.self) { group in
                group.addTask { for await state in states where state == .started { return true }; return false }
                group.addTask { try? await Task.sleep(for: .seconds(10)); return false }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            guard started else {
                SpeedLog.record(["event": "connectError", "error": "sessionStartTimeout"])
                session.stop()
                self.session = nil
                tokens = []
                scheduleRecovery(reason: "sessionStartTimeout")
                return
            }

            // Standalone photo capture failed instantly on every scan (0 bytes in ~20 ms), so frames come
            // from the stream. Medium (504x896) keeps Bluetooth load down; faces at talking distance
            // are still ~150 px.
            guard let camera = try session.addCamera(config: streamConfig) else {
                status = "Glasses camera unavailable"
                session.stop()
                self.session = nil
                tokens = []
                scheduleRecovery(reason: "noCamera")
                return
            }
            attachCamera(camera)
            // Bring the stream up now, not on the first press: spinning it up cost ~830 ms of
            // every identify, and it is the single biggest item on the clock.
            startStream()
            cameraRestartTried = false
            watchFrames()

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
            // Half-built: drop it, and try again rather than leave a dead session behind.
            session?.stop()
            teardown(status: status, keepContext: true)
            scheduleRecovery(reason: "connectError")
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
    /// glasses). Log every transition; an unexpected stop is recovered like any other fault.
    private func sessionChanged(_ state: String, stopped: Bool) {
        SpeedLog.record(["event": "session", "state": state])
        guard stopped, connected else { return }
        teardown(status: "Reconnecting to your glasses…", keepContext: true)
        scheduleRecovery(reason: "sessionStopped")
    }

    /// The one way back from any fault: stop what's left, wait until it has actually stopped, and
    /// connect again. Backoff 0, 2, 4, 8, 15, then every 30 s, for as long as it takes; it resets
    /// once frames have flowed for 30 s. Only Disconnect ends it.
    private func scheduleRecovery(reason: String) {
        guard !userDisconnected, !blockedOnUser, recoveryTask == nil else { return }
        let ladder: [Double] = [0, 2, 4, 8, 15, 30]
        let delay = ladder[min(recoveryAttempt, ladder.count - 1)]
        recoveryAttempt += 1
        SpeedLog.record(["event": "recover", "reason": reason, "attempt": recoveryAttempt, "delayS": delay])
        if !connected || status.hasPrefix("Connected") { status = "Reconnecting to your glasses…" }
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, !self.userDisconnected else { self?.recoveryTask = nil; return }
            await self.restartSession()
            self.recoveryTask = nil
            if !self.connected, !self.connecting { self.scheduleRecovery(reason: "stillDown") }
        }
    }

    private func restartSession() async {
        if let old = session {
            display?.stop()
            old.stop()
            // Starting a new session while the old one is still stopping got the new one stopped
            // too (17:33:15 in Toby's log). Wait for the old one to finish, up to 4 s.
            let deadline = Date().addingTimeInterval(4)
            while old.state != .stopped, old.state != .idle, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        if connected || session != nil { teardown(status: "Reconnecting to your glasses…", keepContext: true) }
        await connect()
    }

    /// Reconnect when the glasses come back (unfolded, back in range).
    private func watchForGlasses() {
        guard watchTask == nil else { return }
        let finder = AutoDeviceSelector(wearables: Wearables.shared)
        watchTask = Task { [weak self] in
            var available = true
            for await id in finder.activeDeviceStream() {
                guard let self else { return }
                if id != nil, !available, !self.connected, !self.connecting {
                    // Back in range: skip the backoff.
                    self.recoveryTask?.cancel(); self.recoveryTask = nil; self.recoveryAttempt = 0
                    self.scheduleRecovery(reason: "glassesAvailable")
                }
                available = id != nil
            }
        }
    }

    func disconnect() {
        userDisconnected = true
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryAttempt = 0
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
            // A press is more looks at the same faces the watcher has been following.
            tracker.update(scan.hits)
        } while hits.isEmpty && frames < 3
        log["frames"] = frames
        log["captureMs"] = ms(since: start)
        let fused = bestTrack()
        guard frames > 0 || fused != nil else {
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
        // One frame is a weak vote (a face in ~1 of 3 low frames, single-frame scores ~0.1 below
        // the fused ones), so the fused track wins whenever it names someone.
        var pick = bestKnown(hits)
        if let fused {
            pick = (fused.track.best, fused.match)
            announced.insert(fused.track.id)
            log["fused"] = true
            log["looks"] = fused.track.looks
        }
        if let pick {
            result = pick.match.map { .known($0, pick.hit) } ?? .unknown(pick.hit)
        } else {
            result = .noFace
        }
        recordSeen()
        log["matchMs"] = ms(since: matchStart)
        if let hit = pick?.hit {
            let ranked = store.ranked(fused.map { $0.track.probe } ?? hit.embedding)
            log["person"] = ranked.first?.person.id
            log["score"] = ranked.first.map { (Double($0.score) * 1000).rounded() / 1000 }
            log["runnerUp"] = ranked.dropFirst().first.map { (Double($0.score) * 1000).rounded() / 1000 }
        }
        // This used to say "known" whenever a face was found, even when the gate refused to name
        // anyone — which made the log read as if matching was working while the lens said "not sure".
        log["outcome"] = pick == nil ? "noFace" : (pick?.match == nil ? "unknown" : "known")
        log["embedder"] = FaceEngine.embedder.name
        log["detector"] = FaceEngine.detectorName
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
        sighted[match.person.id] = Date()
        // The bio's turn ends on its own; hand the lens back to the aid (or shrink the card) then.
        bioTask?.cancel()
        bioTask = Task { [weak self, bioHolds] in
            try? await Task.sleep(for: .seconds(bioHolds + 0.05))
            guard !Task.isCancelled else { return }
            self?.renderLens()
        }
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
        // As if just identified and still in view, so the bio → aid hand-off can be watched.
        resultAt = Date()
        sighted[person.id] = Date()
        bioTask = Task { [weak self, bioHolds] in
            try? await Task.sleep(for: .seconds(bioHolds + 0.05))
            self?.renderLens()
        }
        // No display to write to in a screenshot run, so fill the mirror directly — it is the
        // same description `hud()` would have built.
        lensShot = LensCards.shot(result: result, identifying: false, confirming: confirming,
                                  connected: store?.connectedCount ?? 0)
        renderLens()
    }

    /// MOCK_GLASSES=1: pair simulated Ray-Ban Display glasses (registered, permissions granted)
    /// and mirror their lens into the app, so the whole flow runs without hardware.
    func useMockGlasses() async {
        guard Self.ready else { status = "Glasses SDK unavailable here"; return }
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
        // Dismissing is "show me someone else": let the watch re-offer anyone it is tracking.
        announced.removeAll()
        renderLens()
    }

    /// The aid's lens changed. It goes up now unless a fresh identification holds the lens (then
    /// it shows once that has been read, if it is still current).
    func showAid(_ view: LensView) {
        guard view != aidLens else { return }
        aidLens = view
        renderLens()
        countdown?.cancel()
        countdown = nil
        guard !view.working.isEmpty else { return }
        // The countdown ticks on the lens: one re-send a second while something is in flight.
        countdown = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, !self.aidLens.working.isEmpty else { return }
                if self.lensMode == .aid || self.lensMode == .both { self.renderLens() }
            }
        }
    }
    @ObservationIgnored private var countdown: Task<Void, Never>?

    private func classify(_ face: FaceHit) -> Identification {
        guard let store else { return .noFace }
        return store.match(face.embedding).map { .known($0, face) } ?? .unknown(face)
    }

    /// `keepContext`: a reconnect, not a goodbye. The person on the card and the aid's lens survive
    /// it, so the lens comes back showing what it showed.
    private func teardown(status: String, keepContext: Bool = false) {
        inputTask?.cancel()
        inputTask = nil
        tokens = []
        releaseCameraTokens()
        camera = nil
        display = nil
        displayReady = false
        session = nil
        connected = false
        lensWriter?.cancel()
        lensWriter = nil
        queuedView = nil
        finishWrites(false)
        if !keepContext {
            aidLens = LensView()
            bioTask?.cancel()
            result = .ready
            resultAt = .distantPast
        }
        streamLive = false
        streamState = "none"
        frameWatchdog?.cancel()
        frameWatchdog = nil
        lensShot = nil
        povWatch?.cancel()
        povWatch = nil
        pov = nil
        autoBusy = false
        tracker.reset()
        announced.removeAll()
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

    /// The next frame from the glasses camera, for a press. Never repairs anything itself: a
    /// press used to rebuild the camera on a stale error flag, and that tore down a session that
    /// was delivering 2 fps (17:33:14 in Toby's log). Faults are the watchdog's job.
    private func nextFrame() async -> CIImage? {
        guard camera != nil else {
            scheduleRecovery(reason: "pressNoCamera")
            return nil
        }
        return await frame()
    }

    private func frame() async -> CIImage? {
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

    /// The first frame of a new stream took 6-12 s on Toby's glasses, every time. The old 6 s stall
    /// limit fired before it arrived and tore down a stream that was about to work.
    @ObservationIgnored private var firstFrameGrace: TimeInterval { TimeInterval(Tuning.float("firstFrameGrace", 15)) }
    /// Once frames have flowed (2 fps), this long without one is a stall.
    @ObservationIgnored private var stallAfter: TimeInterval { TimeInterval(Tuning.float("stallAfter", 6)) }

    /// The watch path waits on frames that simply arrive, so a silent stream looks exactly like an
    /// empty room. This notices the silence and repairs it, and it is the only thing that does:
    /// first a camera restart, then the session, then the session again with backoff. It never
    /// stops watching while connected, and never leaves the app connected without a camera.
    private func watchFrames() {
        frameWatchdog?.cancel()
        frameWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                guard self.connected, self.recoveryTask == nil else { continue }
                guard self.camera != nil else {
                    self.scheduleRecovery(reason: "noCamera")
                    continue
                }
                let now = Date()
                let flowing = self.lastFrameAt > self.streamStartedAt
                // Frames for 30 s straight: whatever went wrong before is over.
                if flowing, now.timeIntervalSince(self.lastFrameAt) < 2,
                   now.timeIntervalSince(self.streamStartedAt) > 30, self.recoveryAttempt > 0 || self.cameraRestartTried {
                    self.recoveryAttempt = 0
                    self.cameraRestartTried = false
                }
                // Paused is the glasses' call (folded, off your face, thermal). Give it a minute.
                let paused = self.streamState == "paused" || self.streamState == "waitingForDevice"
                let quiet = now.timeIntervalSince(flowing ? self.lastFrameAt : self.streamStartedAt)
                // A stream the SDK itself calls stopped won't come back by waiting.
                let dead = self.streamState == "stopped"
                let limit = paused ? 60 : dead ? 3 : (flowing ? self.stallAfter : self.firstFrameGrace)
                guard quiet > limit else { continue }
                SpeedLog.record(["event": "frameStall", "quietMs": (quiet * 1000).rounded(),
                                 "flowing": flowing, "stream": self.streamState])
                // Audio on and the stream died before a single frame, twice: the glasses won't
                // stream audio. Drop it rather than lose the camera too.
                if self.streamAudio, !flowing, dead {
                    self.audioStreamFailures += 1
                    if self.audioStreamFailures >= 2 { self.disableStreamAudio(reason: "streamDiesWithAudio") }
                } else if flowing {
                    self.audioStreamFailures = 0
                }
                // On real glasses a camera restart "succeeds" and the new stream dies on its first
                // frame (Critical error, 17:48:09), while a session restart is back streaming in
                // ~2 s. So real glasses go straight to the session; only the simulator tries the camera.
                if self.cameraRestartTried || !self.mocking {
                    self.scheduleRecovery(reason: "frameStall")
                } else {
                    self.cameraRestartTried = true
                    await self.restartCamera()
                }
            }
        }
    }

    private func startStream() {
        guard let camera, !streamLive else { return }
        camera.stream.start()
        streamLive = true
        streamStartedAt = Date()
    }

    /// A fresh camera on the same session: the cheap repair. The old code added a new camera while
    /// the old one was still active, which the SDK refuses (capabilityAlreadyActive): it failed 4
    /// times out of 4. Stop the old one and wait for it to report stopped first. If that still
    /// fails, the session goes.
    private func restartCamera() async {
        guard let session else { return }
        SpeedLog.record(["event": "cameraRestart"])
        let old = camera
        releaseCameraTokens()
        camera = nil
        streamLive = false
        streamState = "none"
        if let old {
            old.stop()
            let deadline = Date().addingTimeInterval(3)
            while old.state != .stopped, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        }
        do {
            guard let fresh = try session.addCamera(config: streamConfig) else { throw CancellationError() }
            attachCamera(fresh)
            startStream()
            SpeedLog.record(["event": "cameraRestartOK"])
        } catch {
            SpeedLog.record(["event": "cameraRestartFailed", "error": "\(error)"])
            scheduleRecovery(reason: "cameraRestartFailed")
        }
    }

    private func attachCamera(_ camera: Camera) {
        liveStreamSettings = streamSettings
        frameSizes.removeAll()
        statsFrom = Date()
        cameraTokens.append(camera.stream.videoFramePublisher.listen { [weak self] frame in
            // Decode on the publisher's own thread. Hopping to the main actor first and calling
            // makeUIImage() there is what made the POV tile stutter: the decode was spending the
            // UI's frame budget. The main actor only ever receives finished images.
            let image = frame.makeUIImage()
            let small = image?.fitted(to: 360)
            Task { @MainActor in
                guard let self else { return }
                self.lastFrameAt = Date()
                self.noteFrame(image)
                // Every frame is already decoded and downscaled above for the face path, whether
                // or not anyone is looking at the phone, so showing it costs one texture upload
                // and no extra radio time. Real glasses arrive at 7 fps: a slideshow, by budget.
                if let small, Date().timeIntervalSince(self.lastPov) > 0.04 {
                    self.lastPov = Date()
                    self.pov = small
                }
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
        // Logged only. "Critical error, the stream should end" arrived at 17:32:17 and frames kept
        // coming at 2 fps for another minute; treating it as fatal is what broke a working stream.
        // If frames really stop, the watchdog sees it.
        cameraTokens.append(camera.stream.errorPublisher.listen { error in
            let message = error.localizedDescription
            Task { @MainActor in SpeedLog.record(["event": "streamError", "error": message]) }
        })
        if streamAudio {
            let sink = audioSink
            cameraTokens.append(camera.stream.audioFramePublisher.listen { [weak self] frame in
                sink.handler?(frame.pcmBuffer)
                Task { @MainActor in self?.audioFrames += 1 }
            })
        }
        cameraTokens.append(camera.stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                let name = "\(state)"
                guard name != self.streamState else { return }
                self.streamState = name
                SpeedLog.record(["event": "stream", "state": name])
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

    /// Counts a delivered frame and, every 10 s, writes one line saying what the link really gave
    /// us: size, true frame rate, and how sharp the faces in it were. Raising `streamRes` is only
    /// worth it if these numbers move — the SDK will happily accept "high" and send you something
    /// else when the radio is busy.
    private func noteFrame(_ image: UIImage?) {
        guard let image else { return }
        let scale = image.scale
        let key = "\(Int(image.size.width * scale))x\(Int(image.size.height * scale))"
        frameSizes[key, default: 0] += 1
        statsFrames += 1
        let now = Date()
        guard now.timeIntervalSince(lastStats) >= 10 else { return }
        lastStats = now
        let seconds = max(now.timeIntervalSince(statsFrom), 0.001)
        var log: [String: Any] = ["event": "streamStats",
                                  "asked": streamSettings,
                                  "sizes": frameSizes.map { "\($0.key)x\($0.value)" }.sorted().joined(separator: ","),
                                  "frames": statsFrames,
                                  "fps": (Double(statsFrames) / seconds * 10).rounded() / 10]
        if streamAudio { log["audioFrames"] = audioFrames; audioFrames = 0 }
        if !sharpSamples.isEmpty {
            let sorted = sharpSamples.sorted()
            log["sharpP10"] = (Double(sorted[max(0, sorted.count / 10)]) * 1000).rounded() / 1000
            log["sharpP50"] = (Double(sorted[sorted.count / 2]) * 1000).rounded() / 1000
            log["faceFrames"] = sorted.count
        }
        SpeedLog.record(log)
        frameSizes.removeAll(); statsFrames = 0; sharpSamples.removeAll(); statsFrom = now
    }

    /// A pushed `streamRes`/`streamFps` only takes effect on a new camera, so swap one in.
    /// This is what makes resolution a 0.3 s tuning push instead of a build.
    func restreamIfSettingsChanged() {
        // OFF by default, and it stays that way until the rebuild path is trustworthy: swapping the
        // camera live on Toby's phone answered with cameraRebuildFailed and cost a session
        // recovery. `liveRestream: true` opts in; otherwise a resolution change waits for the next
        // reconnect, which costs nothing.
        guard Tuning.bool("liveRestream", false) else { return }
        guard connected, let live = liveStreamSettings, live != streamSettings else { return }
        SpeedLog.record(["event": "restream", "from": live, "to": streamSettings])
        Task { await restartCamera() }
    }

    // MARK: - Auto-identify

    /// True when a watch scan should run on this frame, and claims the slot if so.
    private func claimAutoScan() -> Bool {
        guard watching, connected, !identifying, !autoBusy, store != nil else { return false }
        // Aid cards on the lens never pause scanning: `facing`/`present` stay current, which is
        // what the aid's "who is THEM" reads, and a fresh identification may take the lens back.
        // NOTE: a card being up no longer stops the scan. It used to return false for the whole
        // 20 s `cardHolds`, so turning to a new person meant waiting out the old one with the
        // camera effectively off. `cardHolds` now gates only the *display* (see mayShow), and the
        // tracker keeps accumulating evidence about whoever you turned to in the meantime.
        guard Date().timeIntervalSince(lastAutoScan) >= autoInterval else { return false }
        autoBusy = true
        lastAutoScan = Date()
        return true
    }

    /// Whether a new person may take the lens right now.
    private func mayShow(_ id: String) -> Bool {
        // A fresh identification wins the lens over aid cards, so an aid card no longer blocks this.
        guard !identifying else { return false }
        if lastShown[id] != nil, let seen = sighted[id], Date().timeIntervalSince(seen) < absentFor { return false }
        // Someone else is on the card; leave them there for a beat before swapping.
        if case .known(let current, _) = result, current.person.id != id,
           Date().timeIntervalSince(resultAt) < cardHolds { return false }
        return true
    }

    /// Scan a watch frame. Quiet by design: this path only ever writes the lens for a confident,
    /// stable, not-just-shown match. A miss leaves whatever is on the lens exactly as it was —
    /// no "No face found" appearing while nobody asked for anything.
    ///
    /// What changed: a frame is no longer a verdict, it is a vote. Faces are followed between
    /// frames and their embeddings fused, so a blurry look adds information instead of resetting
    /// the state machine. Expected time to a correct auto-identify goes from ~43 s to a couple of
    /// frames, and the blur gate means the frames that would have produced a *wrong* name are
    /// rejected before they are even embedded.
    private func autoScan(_ image: CIImage) async {
        defer { autoBusy = false }
        let start = CFAbsoluteTimeGetCurrent()
        let scan = await scanFaces(image)
        guard let store else { return }
        for hit in scan.hits where hit.sharpness > 0 { sharpSamples.append(hit.sharpness) }
        let frameTime = Date()
        let live = tracker.update(scan.hits, now: frameTime)
        guard !live.isEmpty else {
            if facing != nil { facing = nil }
            return
        }

        // Strongest evidence first; the first track that clears the bar and is allowed on screen wins.
        var chosen: (track: FaceTracker.Track, match: Match)?
        var seenNow: [(id: String, attention: Float)] = []
        let inFrame = live.filter { $0.updated == frameTime }
        let focus = inFrame.map(\.attention).max() ?? 0
        for track in live where track.looks > 0 {
            // A clear look at a strong match is enough on its own; anything weaker has to build up
            // evidence over a couple of frames first.
            // A face followed over several looks has earned the normal bar (minScore/minGap, the
            // same one a press uses); a single look still needs the strict one. The strict bar
            // was only ever cleared by someone looking straight into the glasses, so a person
            // talking to you at an angle never got named.
            let evidenced = track.weight >= minEvidence
            guard let match = evidenced ? store.match(track.probe) : store.confidentMatch(track.probe),
                  evidenced || match.score >= strongScore else { continue }
            let current = track.updated == frameTime
            if current { seenNow.append((match.person.id, track.attention)) }
            guard current, track.attention >= focus * focusShare,
                  !announced.contains(track.id), mayShow(match.person.id) else { continue }
            if let best = chosen, track.attention <= best.track.attention { continue }
            chosen = (track, match)
        }
        // Sightings are recorded after the show decision, so this frame can't silence itself.
        for seen in seenNow { sighted[seen.id] = frameTime }
        let looking = seenNow.max { $0.attention < $1.attention }?.id
        if looking != facing { facing = looking }
        guard let chosen else {
            if scan.timing.gated > 0, scan.timing.faces > 0, Int.random(in: 0..<10) == 0 {
                SpeedLog.record(["event": "autoBlurred", "faces": scan.timing.faces,
                                 "gated": scan.timing.gated,
                                 "sharpness": (Double(scan.timing.bestSharpness) * 1000).rounded() / 1000])
            }
            return
        }

        announced.insert(chosen.track.id)
        result = .known(chosen.match, chosen.track.best)
        recordSeen()
        let ranked = store.ranked(chosen.track.probe)
        var log: [String: Any] = ["event": "autoIdentify", "source": "watch",
                                  "detector": FaceEngine.detectorName,
                                  "attention": (Double(chosen.track.attention) * 100).rounded() / 100,
                                  "inFrame": inFrame.count,
                                  "person": chosen.match.person.id,
                                  "score": (Double(chosen.match.score) * 1000).rounded() / 1000,
                                  "looks": chosen.track.looks,
                                  "evidence": (Double(chosen.track.weight) * 100).rounded() / 100,
                                  "sharpness": (Double(chosen.track.best.sharpness) * 1000).rounded() / 1000,
                                  "aligned": chosen.track.best.aligned,
                                  "ttidMs": ms(since: chosen.track.firstSeen.timeIntervalSinceReferenceDate),
                                  "faces": scan.timing.faces, "embedded": scan.hits.filter(\.usable).count,
                                  "gated": scan.timing.gated,
                                  "detectMs": (scan.timing.detectMs * 10).rounded() / 10,
                                  "embedMs": (scan.timing.embedMs * 10).rounded() / 10,
                                  "scanMs": ms(since: start)]
        log["runnerUp"] = ranked.dropFirst().first.map { (Double($0.score) * 1000).rounded() / 1000 }
        let lensStart = CFAbsoluteTimeGetCurrent()
        if await sendLens() { log["lensMs"] = ms(since: lensStart) }
        log["totalMs"] = ms(since: start)
        SpeedLog.record(log)
    }

    /// Detect every face, crop the four largest, embed the ones sharp enough to be evidence.
    /// An embedding is ~6 ms, so the extra candidates are nearly free, and they are what makes a
    /// second person in the frame matchable at all. The blur gate inside `scan` pays for itself
    /// twice: it skips the embed on frames that could never produce a right answer, and it stops
    /// those frames producing a *wrong* one.
    private func scanFaces(_ image: CIImage) async -> (hits: [FaceHit], timing: FaceTiming) {
        await withCheckedContinuation { done in
            worker.async {
                done.resume(returning: FaceEngine.scan(image, limit: 4, rank: .attention, minFace: FaceEngine.minFacePx))
            }
        }
    }

    /// The face in this frame with the strongest match; when nobody is known, the largest face.
    /// The strongest named match among faces seen in the last `maxAge`, using fused evidence.
    private func bestTrack() -> (track: FaceTracker.Track, match: Match)? {
        guard let store else { return nil }
        var best: (track: FaceTracker.Track, match: Match)?
        for track in tracker.tracks
        where track.looks > 0 && Date().timeIntervalSince(track.updated) <= tracker.maxAge {
            guard let match = store.match(track.probe) else { continue }
            // The face you are looking at, not whoever happens to score highest.
            if let current = best, track.attention <= current.track.attention { continue }
            best = (track, match)
        }
        return best
    }

    private func bestKnown(_ hits: [FaceHit]) -> (hit: FaceHit, match: Match?)? {
        guard let store, let largest = hits.first else { return nil }
        var best: (hit: FaceHit, match: Match)?
        for hit in hits {
            guard let match = store.match(hit.embedding) else { continue }
            if let current = best, hit.attention <= current.hit.attention { continue }
            best = (hit, match)
        }
        if let best { return (best.hit, best.match) }
        return (largest, nil)
    }

    // MARK: - Lens

    private func renderLens() {
        guard displayReady else { return }
        send(lensView())
    }

    /// The person on the card, if the face side has one.
    private var knownPerson: Person? {
        if case .known(let match, _) = result { return match.person }
        return nil
    }

    /// The whole lens as it should be right now: `LensPolicy` picks the face side, the aid, or
    /// both, and this builds that card and its mirror.
    private func currentMode() -> LensMode {
        let person = knownPerson
        let around = person.map { facing == $0.id || present.contains($0.id) } ?? false
        return LensPolicy.mode(identifying: identifying, confirming: confirming, known: person != nil, around: around,
                               sinceIdentified: Date().timeIntervalSince(resultAt), bioHolds: bioHolds,
                               aidArmed: aidArmed, aidEmpty: aidLens.isEmpty)
    }

    private func lensView() -> FlexBox {
        let person = knownPerson
        let mode = currentMode()
        lensMode = mode
        let connected = store?.connectedCount ?? 0
        let avatar: (String) -> UIImage? = { [store] in store?.lensAvatar($0) }
        switch mode {
        case .identity:
            return hud()
        case .aid, .both:
            let partner = mode == .both ? person : nil
            lensShot = LensCards.shot(aid: aidLens, person: partner)
            return LensCards.aid(aidLens, person: partner, avatar: avatar)
        case .compact:
            guard let person else { return hud() }
            lensShot = LensCards.shot(compact: person, identifying: identifying, connected: connected)
            return LensCards.compact(person, avatar: avatar, identifying: identifying, connected: connected,
                                     identify: { [weak self] in Task { @MainActor in await self?.lensIdentify(source: "lens") } })
        case .idle:
            lensShot = LensCards.shot(result: .ready, identifying: false, confirming: confirming, connected: connected)
            return LensCards.hud(result: .ready, avatar: avatar, identifying: false, confirming: confirming,
                                 connected: connected,
                                 identify: { [weak self] in Task { @MainActor in await self?.lensIdentify(source: "lens") } })
        }
    }

    /// The identity HUD as it stands right now. Both lens writers go through here, so this is
    /// also where the phone's mirror is updated — it cannot fall out of step with what was sent.
    private func hud() -> FlexBox {
        let connected = store?.connectedCount ?? 0
        lensShot = LensCards.shot(result: result, identifying: identifying,
                                  confirming: confirming, connected: connected)
        return LensCards.hud(
            result: result,
            avatar: { [store] in store?.lensAvatar($0) },
            identifying: identifying,
            confirming: confirming,
            connected: connected,
            identify: { [weak self] in Task { @MainActor in await self?.lensIdentify(source: "lens") } }
        )
    }

    /// Lens writes, one at a time and newest wins: a burst of updates (an answer streaming in)
    /// collapses to the latest card every `minSendInterval`, and no write ever overlaps another.
    private func send(_ view: FlexBox) {
        queuedView = view
        guard lensWriter == nil else { return }
        lensWriter = Task { [weak self] in
            while let self, !Task.isCancelled, self.queuedView != nil {
                let wait = self.minSendInterval - Date().timeIntervalSince(self.lastSend)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled, let view = self.queuedView else { break }
                self.queuedView = nil
                self.lastSend = Date()
                self.lastWriteOK = await self.write(view)
            }
            self?.lensWriter = nil
            self?.finishWrites(self?.lastWriteOK ?? false)
        }
    }

    private func finishWrites(_ ok: Bool) {
        let waiters = writeWaiters
        writeWaiters = []
        for waiter in waiters { waiter.resume(returning: ok) }
    }

    @discardableResult
    private func write(_ view: FlexBox) async -> Bool {
        guard let display else { return false }
        let start = CFAbsoluteTimeGetCurrent()
        do {
            try await display.send(view)
            let elapsed = ms(since: start)
            if elapsed > 1000 { SpeedLog.record(["event": "lensSlow", "ms": elapsed]) }
            return true
        } catch {
            SpeedLog.record(["event": "lensError", "error": "\(error)"])
            return false
        }
    }

    /// Puts the lens as it now stands through the same queue (a fresh result wins it, see
    /// `LensPolicy`) and waits until it is on the glasses, so the speed log can time it.
    private func sendLens() async -> Bool {
        guard display != nil, displayReady else { return false }
        send(lensView())
        return await withCheckedContinuation { writeWaiters.append($0) }
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
