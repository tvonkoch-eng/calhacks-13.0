import CoreImage
import MWDATCamera
import MWDATCore
import MWDATDisplay
import Observation
import UIKit

/// Meta glasses: streams the glasses camera into face recognition and, on Display glasses,
/// puts the matched person's card on the lens.
@MainActor @Observable final class Glasses {
    var status = "Not connected"
    var connected = false
    var frame: UIImage?
    var faces: [FaceHit] = []

    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var camera: Camera?
    @ObservationIgnored private var display: Display?
    @ObservationIgnored private var tokens: [any AnyListenerToken] = []
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var shown: String?
    @ObservationIgnored private let worker = DispatchQueue(label: "glasses-faces")

    static func configure() {
        do { try Wearables.configure() } catch { print("Wearables.configure failed: \(error)") }
    }

    static func handle(_ url: URL) {
        guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(where: { $0.name == "metaWearablesAction" }) == true else { return }
        Task { _ = try? await Wearables.shared.handleUrl(url) }
    }

    /// Each step that hands off to Meta AI returns; tap Connect again when you're back.
    func connect() async {
        let wearables = Wearables.shared
        do {
            if wearables.registrationState != .registered {
                status = "Approve in Meta AI, then tap Connect again"
                try await wearables.startRegistration()
                return
            }
            if try await wearables.checkPermissionStatus(.camera) != .granted {
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
            let started = Task {
                for await state in session.stateStream() where state == .started { return }
            }
            try session.start()
            await started.value

            guard let camera = try session.addCamera(config: StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 7)) else {
                status = "Glasses camera unavailable"
                return
            }
            tokens.append(camera.stream.videoFramePublisher.listen { [weak self] frame in
                guard let image = frame.makeUIImage() else { return }
                Task { @MainActor in self?.receive(image) }
            })
            tokens.append(camera.stream.errorPublisher.listen { [weak self] error in
                Task { @MainActor in self?.status = error.localizedDescription }
            })
            camera.stream.start()
            self.camera = camera

            if let id = selector.activeDevice, wearables.deviceForIdentifier(id)?.supportsDisplay() == true {
                let display = try session.addDisplay()
                display.start()
                self.display = display
            }
            connected = true
            status = display == nil ? "Connected" : "Connected · lens on"
        } catch {
            status = "\(error)"
        }
    }

    func disconnect() {
        camera?.stop()
        display?.stop()
        session?.stop()
        tokens = []
        camera = nil
        display = nil
        session = nil
        connected = false
        faces = []
        frame = nil
        shown = nil
        status = "Not connected"
    }

    /// Shows a person's card on the lens once per new match.
    func show(_ person: Person) {
        guard let display, person.id != shown else { return }
        shown = person.id
        let facts = Array(person.facts.prefix(2))
        Task {
            try? await display.send(
                FlexBox(direction: .column, spacing: 8) {
                    Text(person.name, style: .heading)
                    Text(person.role, style: .body, color: .secondary)
                    for fact in facts { Text(fact, style: .meta) }
                }
                .padding(20)
                .background(.card)
            )
        }
    }

    private func receive(_ image: UIImage) {
        frame = image
        guard !busy, let ci = CIImage(image: image) else { return }
        busy = true
        worker.async {
            let hits = FaceEngine.faces(in: ci)
            Task { @MainActor in
                self.faces = hits
                self.busy = false
            }
        }
    }
}
