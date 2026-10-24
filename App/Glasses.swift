import AVFoundation
import CoreImage
import MWDATCamera
import MWDATCore
import MWDATDisplay
import MWDATInputs
#if DEBUG
import MWDATMockDevice
import MWDATSpeech
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
    /// Everyone in the conversation (the host decides who: seen in focus, or heard), and whether
    /// the wearer has the floor. Two or more turn the person strip into a row of names.
    private(set) var group: [Member] = []
    private(set) var meSpeaking = false

    func setGroup(_ group: [Member], meSpeaking: Bool) {
        guard group != self.group || meSpeaking != self.meSpeaking else { return }
        let before = currentMode()
        self.group = group
        self.meSpeaking = meSpeaking
        // Only a lens that shows the group needs rewriting; the identity card doesn't.
        let after = currentMode()
        if aidArmed, before != after || [.aid, .both, .compact].contains(after) { renderLens() }
    }

    /// Every confident face in a scanned frame (person ids), whether or not it is announced. The
    /// host builds the conversation's group from these.
    @ObservationIgnored var onSeen: (([String]) -> Void)?

    // MARK: Own voice

    /// The glasses' on-device transcription (MWDATSpeech) of what their own mics hear. Called on
    /// the main actor with each partial and final result. The host uses it to tell the wearer's
    /// lines from everyone else's (App/Speakers.swift); it never feeds the aid's transcript.
    @ObservationIgnored var onOwnSpeech: ((_ text: String, _ final: Bool) -> Void)?
    /// "Off", "Starting", "On", or why not, for the phone.
    private(set) var ownVoice = "Off"
    @ObservationIgnored private var speech: Speech?
    @ObservationIgnored private var speechFailures = 0
    @ObservationIgnored private var speechResults = 0
    /// Not while the stream carries the glasses' mic: two consumers of one mic is asking for the
    /// stream to die, and the level gap between glasses and phone does the job then.
    @ObservationIgnored private var wantsSpeech: Bool {
        Tuning.bool("glassesSpeech", true) && speechFailures < 3 && (!streamAudio || Tuning.bool("speechWithStreamAudio", false))
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
    /// What the link delivered over the last second, for the stream lab: the request is not the result.
    var delivered: Delivered?
    struct Delivered { let size: String; let fps: Double }
    @ObservationIgnored private var secFrom = Date()
    @ObservationIgnored private var secFrames = 0
    /// When on, every frame is written to `Documents/frames` (see `FrameRecorder`), a new run per camera.
    var recordFrames = false {
        didSet {
            guard recordFrames != oldValue else { return }
            if recordFrames, camera != nil { FrameRecorder.shared.start(label: streamLabel) }
            if !recordFrames { FrameRecorder.shared.stop() }
        }
    }

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
    /// Was medium at 2 fps (Toby's call, for battery). Now high at 15: a sweep of every setting on
    /// a real pair (Oct 24) found it the fastest rate that kept full 720x1280 throughout; high at
    /// 30 fell to 504x896 within ~10 s, and per-frame sharpness falls as the rate rises. Face scans
    /// cost the same at every size. Battery is the price; push `streamFps: 2` to go back.
    /// What the currently-attached camera was actually built with, so a pushed change to
    /// `streamRes`/`streamFps` can notice it needs a new camera. The SDK fixes resolution and
    /// frame rate at addCamera time; changing the defaults alone does nothing until then.
    @ObservationIgnored private var liveStreamSettings: String?
    private var streamSettings: String { "\(streamFps)/\(streamRes)" }
    var streamRes: String { UserDefaults.standard.string(forKey: "streamRes") ?? "high" }
    var streamFps: Int { Tuning.int("streamFps", 15) }
    /// Names a recorded run. A simulated pair ignores the knobs (see `streamConfig`), so say so.
    private var streamLabel: String {
        #if DEBUG
        if mocking { return "sim-medium-24" }
        #endif
        return "\(streamRes)-\(streamFps)"
    }

    private var streamConfig: StreamConfiguration {
        #if DEBUG
        // A simulated pair is a local AVCaptureSession with no radio at all.
        if mocking { return StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 24) }
        #endif
        let fps = UInt(streamFps)
        let resolution: StreamingResolution = switch streamRes {
        case "high": .high
        case "low": .low
        default: .medium
        }
        // The glasses' mic rides the camera stream (SDK 1.0.1, experimental): 16 kHz mono PCM,
        // no Bluetooth hands-free route, so iOS's audio is never touched.
        let audio: MWDATCamera.AudioCodec? = streamAudio ? .pcm(sampleRate: audioRate, numberOfChannels: 1) : nil
        return StreamConfiguration(videoCodec: .raw, audioCodec: audio, resolution: resolution, frameRate: fps)
    }

    /// The glasses' mic sample rate. 16 kHz is all speech needs; if streams with it keep dying,
    /// 48 kHz gets one try (the SDK's audio path is experimental and untested at each rate here)
    /// before audio is dropped. Remembered, so a rate that works is used from the start next time.
    private var audioRate: MWDATCamera.AudioSampleRate {
        UserDefaults.standard.integer(forKey: "glassesAudioRate") == 48_000 ? .rate48000 : .rate16000
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

    @ObservationIgnored private var audioStatsFrom = Date()
    @ObservationIgnored private var audioSamples = 0
    @ObservationIgnored private var audioChunks = 0

    /// Is the glasses' audio really arriving, and at what rate: logged every 10 s while it does.
    private func noteAudio(samples: Int, rate: Int) {
        audioFrames += 1
        audioChunks += 1
        audioSamples += samples
        let span = Date().timeIntervalSince(audioStatsFrom)
        guard span >= 10 else { return }
        SpeedLog.record(["event": "glassesAudio", "frames": audioChunks, "rate": rate,
                         "secondsOfAudio": (Double(audioSamples) / Double(max(rate, 1)) * 10).rounded() / 10,
                         "overSeconds": (span * 10).rounded() / 10])
        audioChunks = 0
        audioSamples = 0
        audioStatsFrom = Date()
    }

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
    /// 0.06 s: at 15 fps (67 ms apart) that is every frame. A scan is ~17 ms and `autoBusy`
    /// keeps them from overlapping, so the phone keeps up; the second look — the one that lets a
    /// name go up — now comes one frame after the first instead of two.
    @ObservationIgnored private var autoInterval: TimeInterval { TimeInterval(Tuning.float("autoInterval", 0.06)) }
    /// Faces followed across frames, with their embeddings accumulating. This replaces the old
    /// "two consecutive confident frames, reset on any miss" rule, which discarded every near-miss.
    @ObservationIgnored private let tracker = FaceTracker()
    /// How much accumulated evidence a track needs before it may claim the lens. Weight is the
    /// decayed count of sharp looks, so 1.6 is roughly two good frames or three mediocre ones.
    @ObservationIgnored private var minEvidence: Float { Tuning.float("minEvidence", 1.6) }
    /// Who each track was announced as, so a held card doesn't re-fire — and so a track whose
    /// fused face later settles on somebody else can correct the card (see `recheckLooks`).
    @ObservationIgnored private var announced: [Int: String] = [:]
    /// Consecutive scans a shown track has matched someone *else*: (track, person, count).
    @ObservationIgnored private var dissent: (track: Int, person: String, count: Int)?
    /// Scans in a row a different person must win before a shown name is corrected. 3 is ~200 ms
    /// at 15 fps: long enough not to flicker between two close scores. `recheckLooks`, 0 = off.
    @ObservationIgnored private var recheckLooks: Int { Tuning.int("recheckLooks", 3) }
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
    /// Now 1.5 s: with `followFace` the card tracks whoever you turn to, and this is only the
    /// anti-flicker beat between two people.
    @ObservationIgnored private var cardHolds: TimeInterval { TimeInterval(Tuning.float("cardHolds", 1.5)) }
    /// The card shows whoever you are facing, every time you turn — the most accurate name at all
    /// times. Off restores conversation memory (`absentFor`): each person named once while they
    /// stay around. A run on Oct 24 turning Toby -> Avi -> Toby every ~3 s showed Toby throughout
    /// with conversation memory on, though every look matched clearly (Avi 0.70, gap 0.60).
    @ObservationIgnored private var followFace: Bool { Tuning.bool("followFace", true) }
    /// The card's person keeps it while their face is at least this share of the biggest in view.
    @ObservationIgnored private var mainFaceSlack: CGFloat { CGFloat(Tuning.float("mainFaceSlack", 1.15)) }
    /// With `followFace`, a card whose person has been out of view this long comes down: the lens
    /// shows who is in front of you, not who was. `cardClearAfter`, seconds.
    @ObservationIgnored private var cardClearAfter: TimeInterval { TimeInterval(Tuning.float("cardClearAfter", 0.6)) }
    /// When the card's person was last in view (their track, or a confident match of them).
    @ObservationIgnored private var cardSeenAt = Date.distantPast
    /// The best match for the face in view right now, confident or not, for the live readout.
    var likeness: Likeness?
    struct Likeness: Equatable {
        let name: String
        let score: Float
        let runnerUp: String?
        let gap: Float
        let looks: Int
        /// Clears the bar a name needs to go on the lens.
        let confident: Bool
    }
    private var onCard: String? {
        if case .known(let match, _) = result { return match.person.id }
        return nil
    }
    /// How long a fresh identification owns the whole lens, over any aid card, before the aid may
    /// take it back. Long enough to read a name, a headline and three lines.
    @ObservationIgnored private var bioHolds: TimeInterval { TimeInterval(Tuning.float("bioHolds", 10)) }
    @ObservationIgnored private var bioTask: Task<Void, Never>?
    /// A single look this confident is enough on its own: ArcFace puts the same person at ~0.6-0.7
    /// on a sharp frame and everyone else near 0.
    @ObservationIgnored private var strongScore: Float { Tuning.float("strongScore", 0.55) }

    /// False when the Meta SDK could not start at all — notably in the Simulator, where
    /// `Wearables.configure()` fails and every later touch of `Wearables.shared` traps. Guarding
    /// on it keeps the app itself runnable (and screenshottable) with no glasses stack.
    private(set) static var ready = false

    static func configure() {
        // The stream lab's pickers stored whatever was tried last (often 30 fps). They are gone,
        // so drop those values once and let the high/15 defaults apply; a tuning push still wins.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "streamDefaultsHigh15") {
            defaults.removeObject(forKey: "streamRes")
            defaults.removeObject(forKey: "streamFps")
            defaults.set(true, forKey: "streamDefaultsHigh15")
        }
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
            // Never wait forever on the glasses: with none in sight this hung on "Looking for your
            // glasses" with nothing in the log (20:37, four times). 15 s, then the recovery ladder.
            let devices = finder.activeDeviceStream()
            let found: DeviceIdentifier? = await withTaskGroup(of: DeviceIdentifier?.self) { group in
                group.addTask { for await id in devices { if let id { return id } }; return nil }
                group.addTask { try? await Task.sleep(for: .seconds(15)); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let found else {
                // What the SDK does know: an empty list means Meta AI isn't handing us the glasses at
                // all; a listed pair says which state (link, hinge, worn) kept it from being active.
                let known = wearables.devices.map { id -> String in
                    guard let d = wearables.deviceForIdentifier(id) else { return "\(id): gone" }
                    return "\(d.nameOrId()): link=\(d.linkState) hinge=\(d.hingeState) don=\(d.donState) compat=\(d.compatibility())"
                }
                SpeedLog.record(["event": "connectError", "error": "noGlassesFound", "waitedS": 15,
                                 "registration": "\(wearables.registrationState)", "devices": known])
                scheduleRecovery(reason: "noGlassesFound")
                status = "Can't find your glasses — are they on and connected in Meta AI?"
                return
            }
            SpeedLog.record(["event": "connect", "stage": "glassesFound"])
            // Seen is not the same as linked: a session started before the link is up never starts.
            let linkDeadline = Date().addingTimeInterval(15)
            while let device = wearables.deviceForIdentifier(found),
                  !(device.linkState == .connected && device.compatibility() == .compatible) {
                if device.compatibility() == .deviceUpdateRequired {
                    status = "Update your glasses in the Meta AI app"
                    blockedOnUser = true
                    return
                }
                if Date() > linkDeadline {
                    SpeedLog.record(["event": "connectError", "error": "linkTimeout", "waitedS": 15,
                                     "link": "\(device.linkState)", "compatibility": "\(device.compatibility())"])
                    scheduleRecovery(reason: "linkTimeout")
                    status = "Glasses found but not linked — check them in Meta AI"
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            // Pin the session to the glasses we found; a fresh auto selector can start empty.
            let selector = SpecificDeviceSelector(device: found)

            do throws(PermissionError) {
                // The glasses' mic on the stream needs its own grant; without it every stream
                // that asks for audio dies on its first frame (18:09, five times in a row).
                // The same grant covers the glasses' own transcription (who's talking).
                if streamAudio || wantsSpeech, try await wearables.checkPermissionStatus(.microphone) != .granted {
                    status = "Allow microphone access in Meta AI"
                    if try await wearables.requestPermission(.microphone) != .granted {
                        disableStreamAudio(reason: "micPermissionDenied")
                        speechFailures = 3
                        ownVoice = "Unavailable · no mic access in Meta AI"
                        SpeedLog.record(["event": "ownVoice", "state": "micPermissionDenied"])
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
            attachSpeech(session)

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
            announced[fused.track.id] = fused.match.person.id
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
        resultAt = clockNow
        lastShown[match.person.id] = clockNow
        sighted[match.person.id] = clockNow
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
        await dropMock()
        MockDeviceKit.shared.enable()
        let glasses: any MockGlasses
        do { glasses = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay) } catch {
            SpeedLog.record(["event": "mockPairFailed", "error": "\(error)"])
            status = "Phone simulator failed to start"
            return
        }
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

    /// Unpair every simulated pair, not just the one this launch made, and turn the kit off.
    func dropMock() async {
        let kit = MockDeviceKit.shared
        let stale = kit.pairedDevices
        for device in stale { await kit.unpairDevice(device) }
        if kit.isEnabled { await kit.disable() }
        if !stale.isEmpty { SpeedLog.record(["event": "mockDropped", "pairs": stale.count]) }
        mock = nil
        mocking = false
    }

    /// Swap rigs live, no rebuild: drop the session, change the kit under it, come back up.
    /// Reconnecting is not optional — the session is pinned to one device identifier, and the
    /// simulated pair is a different device than the real one.
    /// No early return when `on == mocking`: a simulated pair left over from an earlier launch got
    /// found by connect() while `mocking` said false, so "Real glasses" did nothing (20:44).
    func useMock(_ on: Bool) async {
        UserDefaults.standard.set(on, forKey: Self.mockKey)
        SpeedLog.record(["event": "rig", "mock": on])
        disconnect()
        mockLens = nil
        if on { await useMockGlasses() } else { await dropMock() }
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
        dissent = nil
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
        speech?.stop()
        speech = nil
        if ownVoice != "Off", !ownVoice.hasPrefix("Unavailable") { ownVoice = "Off" }
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
        delivered = nil
        likeness = nil
        FrameRecorder.shared.stop()
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
        photoVerdict.removeAll(); photoMatch.removeAll(); photoHit.removeAll(); photoTries.removeAll()
        resumePhoto(nil)
        photoBusy = false
        dissent = nil
        resumeFrame(nil)
        self.status = status
    }

    /// Glasses capture button / action button → identify. Needs Inputs enabled in Wearables Developer Center.
    /// The glasses transcribe their own mic on-device. Experimental in the SDK, so every failure is
    /// logged and three of them turn it off for the run: the camera and lens must never pay for it.
    private func attachSpeech(_ session: DeviceSession) {
        guard wantsSpeech else { return }
        let speech: Speech
        do {
            guard let added = try session.addSpeech() else {
                ownVoice = "Unavailable on these glasses"
                speechFailures = 3
                SpeedLog.record(["event": "ownVoice", "state": "unavailable"])
                return
            }
            speech = added
        } catch {
            speechFailures += 1
            ownVoice = "Unavailable · \(error)"
            SpeedLog.record(["event": "ownVoice", "state": "addFailed", "error": "\(error)"])
            return
        }
        self.speech = speech
        ownVoice = "Starting"
        speechResults = 0
        tokens.append(speech.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .started: self.ownVoice = "On"
                case .starting: self.ownVoice = "Starting"
                case .stopping, .stopped: if self.ownVoice == "On" || self.ownVoice == "Starting" { self.ownVoice = "Off" }
                }
                SpeedLog.record(["event": "ownVoice", "state": "\(state)"])
            }
        })
        tokens.append(speech.transcriptionPublisher.listen { [weak self] result in
            let text = result.text, final = result.isFinal, confidence = result.confidence
            Task { @MainActor in
                guard let self else { return }
                self.speechResults += 1
                if final || self.speechResults % 20 == 1 {
                    SpeedLog.record(["event": "ownVoiceText", "text": String(text.prefix(120)), "final": final,
                                     "confidence": (Double(confidence) * 100).rounded() / 100])
                }
                self.onOwnSpeech?(text, final)
            }
        })
        tokens.append(speech.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.speechFailures += 1
                self.ownVoice = "Error · \(error)"
                SpeedLog.record(["event": "ownVoice", "state": "error", "error": "\(error)", "failures": self.speechFailures])
                // One retry after a beat; past three failures it stays off until relaunch.
                guard self.wantsSpeech, self.speech === speech else { return }
                try? await Task.sleep(for: .seconds(3))
                guard self.speech === speech, speech.state == .stopped else { return }
                speech.start()
            }
        })
        speech.start()
    }

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
                // A still in flight can pause video for a moment; don't call that a stall.
                guard !self.photoBusy, Date().timeIntervalSince(self.lastPhotoAt) > 4 else { continue }
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
                // Audio on and the stream died within seconds of starting, twice: the glasses won't
                // stream audio. Drop it rather than lose the camera too. (Not "before any frame":
                // these streams get one frame out before the critical error, 18:22.)
                let diedYoung = dead && self.lastFrameAt.timeIntervalSince(self.streamStartedAt) < 5
                if self.streamAudio, diedYoung {
                    self.audioStreamFailures += 1
                    if self.audioStreamFailures >= 2 {
                        if self.audioRate == .rate16000 {
                            UserDefaults.standard.set(48_000, forKey: "glassesAudioRate")
                            self.audioStreamFailures = 0
                            SpeedLog.record(["event": "streamAudioRate", "to": 48_000, "reason": "streamDiesWithAudio"])
                        } else {
                            UserDefaults.standard.removeObject(forKey: "glassesAudioRate")
                            self.disableStreamAudio(reason: "streamDiesWithAudio")
                        }
                    }
                } else if flowing, !dead {
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

    /// One decoded frame, from the glasses or from a replay: counted, shown, then scanned.
    private func ingest(_ image: UIImage?, small: UIImage?) async {
        lastFrameAt = Date()
        noteFrame(image)
        // Every frame is already decoded and downscaled for the face path, whether or not anyone
        // is looking at the phone, so showing it costs one texture upload and no extra radio time.
        if let small, Date().timeIntervalSince(lastPov) > 0.04 {
            lastPov = Date()
            pov = small
        }
        // A press parked on a continuation always wins the frame.
        if frameWaiter != nil {
            resumeFrame(image.flatMap { CIImage(image: $0) })
            return
        }
        // Otherwise the watch gets a look, at its own throttled cadence.
        guard claimAutoScan() else { return }
        guard let ci = image.flatMap({ CIImage(image: $0) }) else {
            autoBusy = false
            return
        }
        await autoScan(ci)
    }

    // MARK: - Replay

    /// True while a recorded run is being fed through the pipeline instead of the glasses.
    private(set) var replaying = false
    /// The face path's clock: wall time, or during a replay the time the current frame was
    /// recorded at. Every gate the matcher has (scan cadence, card hold, tracker age) reads this,
    /// so a replay decides exactly as the phone would whatever speed the simulator runs at.
    @ObservationIgnored private var replayNow: Date?
    private var clockNow: Date { replayNow ?? Date() }
    /// A lens write in flight during a replay: the mirror changes when the recorded clock gets there.
    @ObservationIgnored private var replayLensDue: Date?
    @ObservationIgnored private var replayLensWrites = 0
    @ObservationIgnored private var replayBase = Date()
    /// What a face scan cost on the phone (speed log median, Oct 24). The simulator runs Vision on
    /// the CPU at ~10x that, so a replay charges the phone's cost, not its own.
    @ObservationIgnored private var replayScanMs: Int { Tuning.int("replayScanMs", 10) }
    @ObservationIgnored private var replayTask: Task<Void, Never>?
    /// What a lens write cost on the real pair (median of Oct 24's logs). A replay waits this long
    /// before the mirror changes, so the timing on screen is the timing on the glasses.
    @ObservationIgnored private var replayLensMs: Int { Tuning.int("replayLensMs", 850) }

    /// Plays a recorded run through the live path — frame handling, face scans, tracker, card
    /// rules, lens mirror — at the pace it was recorded. Needs no glasses, so it runs in the
    /// simulator: the way to see what a matcher change does to a real run.
    func replay(_ run: FrameRun) {
        guard !connected || replaying else {
            status = "Disconnect the glasses to replay"
            return
        }
        replayTask?.cancel()
        replayTask = Task { [weak self] in
            guard let self else { return }
            let base = Date()
            self.replayNow = base
            self.replayBase = base
            self.startReplay(run)
            let wall = ContinuousClock()
            let wallStart = wall.now
            // Until then the phone would still be scanning or writing the lens: frames still show,
            // but none gets a scan — exactly what autoBusy does to the live stream.
            var busyUntil = Date.distantPast
            for frame in run.frames {
                // Watchable: never ahead of real time. Falling behind is fine, the decisions run on
                // the recorded clock.
                try? await wall.sleep(until: wallStart + .milliseconds(frame.ms))
                guard !Task.isCancelled else { return }
                let at = base.addingTimeInterval(Double(frame.ms) / 1000)
                self.replayNow = at
                if let due = self.replayLensDue, at >= due {
                    self.replayLensDue = nil
                    _ = self.lensView()
                }
                let url = frame.url
                let decoded = await Task.detached(priority: .userInitiated) { () -> (UIImage?, UIImage?) in
                    let image = UIImage(contentsOfFile: url.path)
                    return (image, image?.fitted(to: 360))
                }.value
                self.autoBusy = at < busyUntil
                let writes = self.replayLensWrites
                let scansBefore = self.lastAutoScan
                await self.ingest(decoded.0, small: decoded.1)
                if self.lastAutoScan != scansBefore {
                    let lens = self.replayLensWrites != writes ? Double(self.replayLensMs) : 0
                    busyUntil = at.addingTimeInterval((Double(self.replayScanMs) + lens) / 1000)
                }
            }
            if self.replayLensDue != nil { self.replayLensDue = nil; _ = self.lensView() }
            try? await Task.sleep(for: .seconds(2))
            self.replaying = false
            self.replayNow = nil
            self.connected = false
            self.status = "Replay finished · \(run.asked)"
        }
    }

    /// One line per scan during a replay: every live track, its fused best match and margin, and
    /// who it was announced as — what the matcher saw, frame by frame, on the recorded clock.
    private func logReplayScan(_ live: [FaceTracker.Track], frameTime: Date, store: Store) {
        let tracks: [[String: Any]] = live.map { track in
            let ranked = track.looks > 0 ? store.ranked(track.probe) : []
            var t: [String: Any] = ["id": track.id, "looks": track.looks, "w": (Double(track.weight) * 100).rounded() / 100,
                                    "px": Int(facePx(track)), "now": track.updated == frameTime]
            if let top = ranked.first {
                t["top"] = top.person.id
                t["score"] = (Double(top.score) * 1000).rounded() / 1000
                t["gap"] = (Double(top.score - (ranked.dropFirst().first?.score ?? 0)) * 1000).rounded() / 1000
            }
            if let shown = announced[track.id] { t["shown"] = shown }
            return t
        }
        SpeedLog.record(["event": "replayScan", "ms": Int(frameTime.timeIntervalSince(replayBase) * 1000),
                         "card": onCard ?? "", "tracks": tracks])
    }

    private func startReplay(_ run: FrameRun) {
        tracker.reset()
        announced.removeAll()
        dissent = nil
        sighted.removeAll()
        lastShown.removeAll()
        lastAutoScan = .distantPast
        replayLensDue = nil
        result = .ready
        resultAt = .distantPast
        likeness = nil
        pov = nil
        autoBusy = false
        frameSizes.removeAll()
        statsFrom = Date()
        replaying = true
        connected = true
        status = "Replaying \(run.asked)…"
        _ = lensView()
        SpeedLog.record(["event": "replay", "run": run.name])
    }

    private func attachCamera(_ camera: Camera) {
        liveStreamSettings = streamSettings
        frameSizes.removeAll()
        statsFrom = Date()
        if recordFrames { FrameRecorder.shared.start(label: streamLabel) }
        let recorder = FrameRecorder.shared
        cameraTokens.append(camera.stream.videoFramePublisher.listen { [weak self] frame in
            // Decode on the publisher's own thread. Hopping to the main actor first and calling
            // makeUIImage() there is what made the POV tile stutter: the decode was spending the
            // UI's frame budget. The main actor only ever receives finished images.
            let image = frame.makeUIImage()
            if let image, recorder.isRecording { recorder.save(image) }
            let small = image?.fitted(to: 360)
            Task { @MainActor in await self?.ingest(image, small: small) }
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
                let samples = Int(frame.pcmBuffer.frameLength), rate = Int(frame.pcmBuffer.format.sampleRate)
                Task { @MainActor in self?.noteAudio(samples: samples, rate: rate) }
            })
        }
        cameraTokens.append(camera.stream.photoDataPublisher.listen { [weak self] photo in
            let data = photo.data
            Task { @MainActor in self?.resumePhoto(data) }
        })
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
        secFrames += 1
        let now = clockNow
        let second = now.timeIntervalSince(secFrom)
        if second >= 1 {
            delivered = Delivered(size: key, fps: (Double(secFrames) / second * 10).rounded() / 10)
            secFrames = 0
            secFrom = now
        }
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
        guard watching || replaying, connected, !identifying, !autoBusy, store != nil else { return false }
        // Aid cards on the lens never pause scanning: `facing`/`present` stay current, which is
        // what the aid's "who is THEM" reads, and a fresh identification may take the lens back.
        // NOTE: a card being up no longer stops the scan. It used to return false for the whole
        // 20 s `cardHolds`, so turning to a new person meant waiting out the old one with the
        // camera effectively off. `cardHolds` now gates only the *display* (see mayShow), and the
        // tracker keeps accumulating evidence about whoever you turned to in the meantime.
        guard clockNow.timeIntervalSince(lastAutoScan) >= autoInterval else { return false }
        autoBusy = true
        lastAutoScan = clockNow
        return true
    }

    /// Takes the card down once its person has been out of view for `cardClearAfter`. Not awaited:
    /// clearing must not hold up the scan the way a new name's write does.
    private func clearCardIfGone(_ now: Date) {
        guard followFace, let card = onCard, !identifying,
              now.timeIntervalSince(max(cardSeenAt, resultAt)) >= cardClearAfter else { return }
        var log: [String: Any] = ["event": "autoClear", "person": card]
        if replaying { log["replayMs"] = Int(now.timeIntervalSince(replayBase) * 1000) }
        SpeedLog.record(log)
        result = .ready
        resultAt = now
        if replaying {
            replayLensDue = now.addingTimeInterval(Double(replayLensMs) / 1000)
        } else {
            renderLens()
        }
    }

    /// The clearest face in view and how much it looks like its best match, every scan.
    private func updateLikeness(_ inView: [FaceTracker.Track], store: Store) {
        var best: Likeness?
        for track in inView {
            let ranked = store.ranked(track.probe)
            guard let top = ranked.first else { continue }
            let next = ranked.dropFirst().first
            let candidate = Likeness(name: top.person.name, score: top.score, runnerUp: next?.person.name,
                                     gap: top.score - (next?.score ?? 0), looks: track.looks,
                                     confident: track.weight >= minEvidence && store.confidentMatch(track.probe) != nil)
            if let current = best, candidate.score <= current.score { continue }
            best = candidate
        }
        if best != likeness { likeness = best }
    }

    /// Whether a new person may take the lens right now.
    private func mayShow(_ id: String) -> Bool {
        // A fresh identification wins the lens over aid cards, so an aid card no longer blocks this.
        guard !identifying else { return false }
        if followFace {
            guard onCard != id else { return false }
            if onCard != nil, clockNow.timeIntervalSince(resultAt) < cardHolds { return false }
            return true
        }
        if lastShown[id] != nil, let seen = sighted[id], clockNow.timeIntervalSince(seen) < absentFor { return false }
        // Someone else is on the card; leave them there for a beat before swapping.
        if case .known(let current, _) = result, current.person.id != id,
           clockNow.timeIntervalSince(resultAt) < cardHolds { return false }
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
        let frameTime = clockNow
        let live = tracker.update(scan.hits, now: frameTime)
        guard !live.isEmpty else {
            if facing != nil { facing = nil }
            if likeness != nil { likeness = nil }
            clearCardIfGone(frameTime)
            return
        }

        // Strongest evidence first; the first track that clears the bar and is allowed on screen wins.
        // A track that already had its turn keeps being matched: memory no longer fades, so its
        // fused face only gets better, and if it settles on someone else for `recheckLooks` scans
        // in a row the card is corrected rather than left wrong for 20 s.
        var chosen: (track: FaceTracker.Track, match: Match)?
        var correcting = false
        var seenNow: [(id: String, score: Float)] = []
        frameWidth = image.extent.width
        updateLikeness(live.filter { $0.updated == frameTime && $0.looks > 0 }, store: store)
        if replaying { logReplayScan(live, frameTime: frameTime, store: store) }
        // The main face: the biggest one in view, and the only one that may take the card. The
        // person already on it keeps it while their face is within `mainFaceSlack` of the biggest,
        // so two people about the same size don't trade the card back and forth (Avi and Joaquin
        // swapped four times in 10 s of the Oct 24 replay).
        let inView = live.filter { $0.updated == frameTime }
        let cardTrack = onCard.flatMap { card in inView.first { announced[$0.id] == card } }
        var main = inView.max { facePx($0) < facePx($1) }
        if let cardTrack, let biggest = main, facePx(cardTrack) * mainFaceSlack >= facePx(biggest) { main = cardTrack }
        if cardTrack != nil { cardSeenAt = frameTime }
        for track in live where track.weight >= minEvidence {
            guard let match = store.confidentMatch(track.probe) else { continue }
            if track.updated == frameTime { seenNow.append((match.person.id, match.score)) }
            // Toby's floor: a stream match on a face this small once named someone who wasn't there.
            guard facePx(track) >= minAnnouncePx else { continue }
            guard !followFace || track.id == main?.id else { continue }
            var isCorrection = false
            if let shownAs = announced[track.id], shownAs == match.person.id {
                if dissent?.track == track.id { dissent = nil }
                // Same face, same name. Only worth showing again if the card has moved on to
                // someone else while you looked away (followFace).
                guard followFace, onCard != shownAs else { continue }
            } else if announced[track.id] != nil {
                guard recheckLooks > 0 else { continue }
                let count = dissent.map { $0.track == track.id && $0.person == match.person.id ? $0.count + 1 : 1 } ?? 1
                dissent = (track.id, match.person.id, count)
                guard count >= recheckLooks else { continue }
                isCorrection = true
            }
            if let current = chosen, match.score <= current.match.score { continue }
            chosen = (track, match)
            correcting = isCorrection
        }
        // A correction is the same face, so it skips the card-hold and re-announce waits; a press
        // still owns the lens. Decided before sightings are recorded, so this frame can't silence itself.
        let allowed = chosen.map { correcting ? !identifying : mayShow($0.match.person.id) } ?? false
        for seen in seenNow { sighted[seen.id] = frameTime }
        if let card = onCard, seenNow.contains(where: { $0.id == card }) { cardSeenAt = frameTime }
        if chosen == nil || !allowed { clearCardIfGone(frameTime) }
        onSeen?(seenNow.map(\.id))
        // Who the wearer is facing, for the aid: the clearest match in view right now.
        let looking = seenNow.max { $0.score < $1.score }?.id
        if looking != facing { facing = looking }
        guard let chosen, allowed else {
            if scan.timing.gated > 0, scan.timing.faces > 0, Int.random(in: 0..<10) == 0 {
                SpeedLog.record(["event": "autoBlurred", "faces": scan.timing.faces,
                                 "gated": scan.timing.gated,
                                 "sharpness": (Double(scan.timing.bestSharpness) * 1000).rounded() / 1000])
            }
            return
        }

        if correcting {
            SpeedLog.record(["event": "autoCorrect", "from": announced[chosen.track.id] ?? "",
                             "to": chosen.match.person.id, "looks": chosen.track.looks])
            dissent = nil
        }
        announced[chosen.track.id] = chosen.match.person.id
        result = .known(chosen.match, chosen.track.best)
        recordSeen()
        let ranked = store.ranked(chosen.track.probe)
        var log: [String: Any] = ["event": correcting ? "autoCorrected" : "autoIdentify", "source": "watch",
                                  "facePx": Int(facePx(chosen.track)),
                                  "detector": FaceEngine.detectorName,
                                  "inFrame": live.filter { $0.updated == frameTime }.count,
                                  "person": chosen.match.person.id,
                                  "score": (Double(chosen.match.score) * 1000).rounded() / 1000,
                                  "looks": chosen.track.looks,
                                  "evidence": (Double(chosen.track.weight) * 100).rounded() / 100,
                                  "sharpness": (Double(chosen.track.best.sharpness) * 1000).rounded() / 1000,
                                  "aligned": chosen.track.best.aligned,
                                  "ttidMs": (clockNow.timeIntervalSince(chosen.track.firstSeen) * 1000).rounded(),
                                  "faces": scan.timing.faces, "embedded": scan.hits.filter(\.usable).count,
                                  "gated": scan.timing.gated,
                                  "detectMs": (scan.timing.detectMs * 10).rounded() / 10,
                                  "embedMs": (scan.timing.embedMs * 10).rounded() / 10,
                                  "scanMs": ms(since: start)]
        log["runnerUp"] = ranked.dropFirst().first.map { (Double($0.score) * 1000).rounded() / 1000 }
        let lensStart = CFAbsoluteTimeGetCurrent()
        if await sendLens() { log["lensMs"] = ms(since: lensStart) }
        log["totalMs"] = ms(since: start)
        if replaying { log["replayMs"] = Int(clockNow.timeIntervalSince(replayBase) * 1000) }
        SpeedLog.record(log)
    }

    /// Detect every face, crop the four largest, embed the ones sharp enough to be evidence.
    /// An embedding is ~6 ms, so the extra candidates are nearly free, and they are what makes a
    /// second person in the frame matchable at all. The blur gate inside `scan` pays for itself
    /// twice: it skips the embed on frames that could never produce a right answer, and it stops
    /// those frames producing a *wrong* one.
    // MARK: - High-resolution confirmation
    //
    // The stream is 2 fps and the SDK delivers it at 360x640 more often than the 504x896 asked
    // for, so a face at talking distance is ~50-80 px: enough to find and follow, not enough to
    // name reliably. A stream match named Mirabelle (0.63) on a small face at the edge of view when
    // she wasn't there. So the stream only finds and tracks; a new face in focus gets one or two
    // full-resolution stills (stream.capturePhoto) and is named only if the still matches clearly.
    // If stills don't work on this pair, naming falls back to the stream with a minimum face size.

    @ObservationIgnored private var photoConfirm: Bool { Tuning.bool("photoConfirm", true) }
    /// Below this many pixels wide in the stream frame, a stream-only match is never announced.
    @ObservationIgnored private var minAnnouncePx: CGFloat { CGFloat(Tuning.float("minAnnouncePx", 56)) }
    @ObservationIgnored private var frameWidth: CGFloat = 360
    /// Per track: the confirmed person id, or "" when the still showed nobody on the roster.
    @ObservationIgnored private var photoVerdict: [Int: String] = [:]
    @ObservationIgnored private var photoMatch: [Int: Match] = [:]
    @ObservationIgnored private var photoHit: [Int: FaceHit] = [:]
    @ObservationIgnored private var photoTries: [Int: Int] = [:]
    @ObservationIgnored private var photoBusy = false
    @ObservationIgnored private var lastPhotoAt = Date.distantPast
    @ObservationIgnored private var photoFailures = 0
    @ObservationIgnored private var photoUnavailableUntil = Date.distantPast
    @ObservationIgnored private var photoWaiter: CheckedContinuation<Data?, Never>?
    @ObservationIgnored private var photoRequest = UUID()

    private var usePhotos: Bool { photoConfirm && camera != nil && Date() > photoUnavailableUntil }

    private func facePx(_ track: FaceTracker.Track) -> CGFloat { track.best.box.width * frameWidth }

    private func requestPhoto(_ track: FaceTracker.Track) {
        guard !photoBusy, (photoTries[track.id] ?? 0) < 2, Date().timeIntervalSince(lastPhotoAt) > 1.5 else { return }
        photoBusy = true
        photoTries[track.id, default: 0] += 1
        lastPhotoAt = Date()
        let id = track.id, box = track.box
        Task { await confirmByPhoto(track: id, box: box) }
    }

    private func confirmByPhoto(track id: Int, box: CGRect) async {
        defer { photoBusy = false; lastPhotoAt = Date() }
        let start = CFAbsoluteTimeGetCurrent()
        var log: [String: Any] = ["event": "photoConfirm", "track": id, "try": photoTries[id] ?? 1]
        guard let data = await takePhoto(), let image = CIImage(data: data) else {
            photoFailures += 1
            log["outcome"] = "noPhoto"
            log["ms"] = ms(since: start)
            if photoFailures >= 2 {
                // This pair won't take stills mid-stream: name from the stream (with the size
                // floor) for a while instead of waiting on photos that never come.
                photoUnavailableUntil = Date().addingTimeInterval(300)
                log["photosOff"] = 300
            }
            SpeedLog.record(log)
            return
        }
        photoFailures = 0
        log["bytes"] = data.count
        log["width"] = Int(image.extent.width)
        log["height"] = Int(image.extent.height)
        log["photoMs"] = ms(since: start)
        let scan = await withCheckedContinuation { done in
            worker.async { done.resume(returning: FaceEngine.scan(image, limit: 4, rank: .largest, minFace: 40)) }
        }
        log["faces"] = scan.hits.count
        // The still and the stream frame cover nearly the same view; take the face nearest where
        // the tracked one was, else the most attended.
        let center = CGPoint(x: box.midX, y: box.midY)
        let usable = scan.hits.filter(\.usable)
        let hit = usable.min { hypot($0.box.midX - center.x, $0.box.midY - center.y) < hypot($1.box.midX - center.x, $1.box.midY - center.y) }
        guard let hit, let store else {
            log["outcome"] = "noFace"
            if (photoTries[id] ?? 0) >= 2 { photoVerdict[id] = "" }
            SpeedLog.record(log)
            return
        }
        let ranked = store.ranked(hit.embedding)
        log["facePx"] = Int(hit.box.width * image.extent.width)
        log["score"] = ranked.first.map { (Double($0.score) * 1000).rounded() / 1000 }
        log["runnerUp"] = ranked.dropFirst().first.map { (Double($0.score) * 1000).rounded() / 1000 }
        if let match = store.confidentMatch(hit.embedding) {
            photoVerdict[id] = match.person.id
            photoMatch[id] = match
            photoHit[id] = hit
            log["person"] = match.person.id
            log["outcome"] = "confirmed"
        } else {
            photoVerdict[id] = ""
            log["outcome"] = "nobody"
        }
        log["ms"] = ms(since: start)
        SpeedLog.record(log)
    }

    /// One full-resolution still off the running stream, or nil within 6 s.
    private func takePhoto() async -> Data? {
        guard let camera, camera.stream.capturePhoto(format: .jpeg) else { return nil }
        let request = UUID()
        photoRequest = request
        return await withCheckedContinuation { done in
            photoWaiter = done
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard let self, self.photoRequest == request else { return }
                self.resumePhoto(nil)
            }
        }
    }

    private func resumePhoto(_ data: Data?) {
        photoWaiter?.resume(returning: data)
        photoWaiter = nil
    }

    private func scanFaces(_ image: CIImage) async -> (hits: [FaceHit], timing: FaceTiming) {
        await withCheckedContinuation { done in
            worker.async {
                done.resume(returning: FaceEngine.scan(image, limit: 4, rank: .largest, minFace: FaceEngine.minFacePx))
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
            if let current = best, match.score <= current.match.score { continue }
            best = (track, match)
        }
        return best
    }

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
        // A group of two or more is "who you're talking to" whether or not anyone's card is up.
        let grouped = group.count >= 2
        let around = grouped || (person.map { facing == $0.id || present.contains($0.id) } ?? false)
        return LensPolicy.mode(identifying: identifying, confirming: confirming, known: person != nil || grouped, around: around,
                               sinceIdentified: clockNow.timeIntervalSince(resultAt), bioHolds: bioHolds,
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
            let grouped = mode == .both && group.count >= 2
            let partner = mode == .both && !grouped ? person : nil
            let members = grouped ? group : []
            lensShot = LensCards.shot(aid: aidLens, person: partner, group: members, meSpeaking: meSpeaking)
            return LensCards.aid(aidLens, person: partner, group: members, meSpeaking: meSpeaking, avatar: avatar)
        case .compact:
            if group.count >= 2 {
                lensShot = LensCards.shot(compact: group, meSpeaking: meSpeaking)
                return LensCards.compact(group: group, meSpeaking: meSpeaking, avatar: avatar)
            }
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
        if replaying {
            replayLensDue = clockNow.addingTimeInterval(Double(replayLensMs) / 1000)
            replayLensWrites += 1
            return true
        }
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
