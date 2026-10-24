import MWDATCore
import MWDATDisplay
import MWDATMockDevice
import Observation
import UIKit

/// Simulated Meta Ray-Ban Display glasses. Sends real Display DSL views through the real SDK;
/// MockDeviceKit renders them in `previewView` exactly as the lens would.
@MainActor @Observable final class Lab {
    var status = "Starting"
    var previewView: UIView?
    var page = 0 {
        didSet { Task { await show() } }
    }

    @ObservationIgnored private var glasses: (any MockGlasses)?
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var display: Display?
    @ObservationIgnored private var tokens: [any AnyListenerToken] = []

    func start() async {
        do {
            try Wearables.configure()
            MockDeviceKit.shared.enable()
            let glasses = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
            self.glasses = glasses
            glasses.powerOn()
            glasses.don()
            previewView = glasses.services.display.createPreviewView()

            status = "Waiting for simulated glasses"
            while !ready(glasses.deviceIdentifier) {
                let device = Wearables.shared.deviceForIdentifier(glasses.deviceIdentifier)
                status = "Waiting: \(device.map { "\($0.linkState) · \($0.compatibility())" } ?? "no device yet")"
                try await Task.sleep(for: .milliseconds(100))
            }

            let selector = SpecificDeviceSelector(device: glasses.deviceIdentifier)
            let session = try Wearables.shared.createSession(deviceSelector: selector)
            self.session = session
            let started = Task { for await state in session.stateStream() where state == .started { return } }
            try session.start()
            await started.value

            let display = try session.addDisplay()
            self.display = display
            let shown = Task { [weak self] in
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    var resumed = false
                    let token = display.statePublisher.listen { state in
                        guard state == .started, !resumed else { return }
                        resumed = true
                        done.resume()
                    }
                    Task { @MainActor in self?.tokens.append(token) }
                }
            }
            display.start()
            await shown.value
            status = "Live"
            await show()
        } catch {
            status = "\(error)"
        }
    }

    private func ready(_ id: DeviceIdentifier) -> Bool {
        guard let device = Wearables.shared.deviceForIdentifier(id) else { return false }
        return device.linkState == .connected && device.compatibility() == .compatible
    }

    private func show() async {
        guard let display else { return }
        do {
            try await display.send(Gallery.pages[page].view { [weak self] next in
                Task { @MainActor in self?.page = next }
            })
        } catch {
            status = "Send failed: \(error)"
        }
    }
}
