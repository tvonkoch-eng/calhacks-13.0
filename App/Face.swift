import AVFoundation
import CoreImage
import SwiftUI
import Vision

/// One face found in a frame: where it is, its embedding, and a square crop for the avatar.
struct FaceHit {
    let embedding: [Float]
    let crop: CGImage
    let area: CGFloat
}

/// Where the time went in one scan (milliseconds).
struct FaceTiming {
    var detectMs = 0.0
    var embedMs = 0.0
    var faces = 0
}

enum FaceEngine {
    private static let context = CIContext()

    /// Detects faces (largest first) and embeds each one with a Vision feature print.
    static func faces(in image: CIImage, limit: Int = .max) -> [FaceHit] {
        scan(image, limit: limit).hits
    }

    /// Detection runs on every face; only the `limit` largest get embedded (embedding is the slow part).
    static func scan(_ image: CIImage, limit: Int = .max) -> (hits: [FaceHit], timing: FaceTiming) {
        var timing = FaceTiming()
        var start = CFAbsoluteTimeGetCurrent()
        let detect = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(ciImage: image).perform([detect])
        timing.detectMs = (CFAbsoluteTimeGetCurrent() - start) * 1000

        let faces = (detect.results ?? []).sorted {
            $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height
        }
        timing.faces = faces.count

        start = CFAbsoluteTimeGetCurrent()
        let hits: [FaceHit] = faces.prefix(limit).compactMap { crop(image, $0) }
        timing.embedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        return (hits, timing)
    }

    /// Cuts the face out of the frame *upright*.
    ///
    /// A feature print is a whole-image descriptor, so it compares a face to the gallery in
    /// whatever orientation the pixels arrived in. Vision reports the in-plane roll of each face;
    /// rotating it out puts every crop — live frames and bundled reference photos alike — into one
    /// upright space. Measured on the real references: a frame rotated 90 degrees scored 0.78
    /// against an upright gallery with the runner-up only 0.06 behind (82% correct); de-rolled,
    /// the same frames score 0.97 with a 0.26 margin and 100% correct.
    ///
    /// It also absorbs an ordinary tilted head, which used to eat the same margin.
    private static func crop(_ image: CIImage, _ face: VNFaceObservation) -> FaceHit? {
        let extent = image.extent
        let box = VNImageRectForNormalizedRect(face.boundingBox, Int(extent.width), Int(extent.height))
            .offsetBy(dx: extent.minX, dy: extent.minY)
        // Rotating about the face's own centre leaves that centre where it is, so the square below
        // still frames the face in the rotated image.
        let centre = CGPoint(x: box.midX, y: box.midY)
        var source = image
        let roll = CGFloat(face.roll?.doubleValue ?? 0)
        if abs(roll) > 0.01 {
            source = image.transformed(by: CGAffineTransform(translationX: centre.x, y: centre.y)
                .rotated(by: -roll)
                .translatedBy(x: -centre.x, y: -centre.y))
        }
        let side = max(box.width, box.height) * 1.25
        let square = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
            .intersection(source.extent)
        // 40 px, not 60: feature prints still hold up on small crops, and 60 silently discarded
        // anyone standing a couple of metres away.
        guard square.width >= 40,
              let cropped = context.createCGImage(source, from: square),
              let embedding = embed(cropped) else { return nil }
        return FaceHit(embedding: embedding, crop: cropped, area: box.width * box.height)
    }

    /// Loads the Vision models up front so the first identify doesn't pay for it.
    static func warmUp() {
        let blank = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
        try? VNImageRequestHandler(ciImage: blank).perform([VNDetectFaceRectanglesRequest()])
        if let cg = context.createCGImage(blank, from: blank.extent) { _ = embed(cg) }
    }

    private static func embed(_ image: CGImage) -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let print = request.results?.first, print.elementType == .float else { return nil }
        var v = print.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        for i in v.indices { v[i] /= norm }
        return v
    }
}

/// Back/front camera that runs face detection on ~4 frames a second.
final class PhoneCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onFaces: (([FaceHit]) -> Void)?
    private let queue = DispatchQueue(label: "camera")
    private let output = AVCaptureVideoDataOutput()
    private var last = Date.distantPast

    func start(front: Bool) {
        queue.async { [self] in
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720
            session.inputs.forEach(session.removeInput)
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back),
               let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            }
            if session.outputs.isEmpty, session.canAddOutput(output) {
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                session.addOutput(output)
            }
            if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard Date().timeIntervalSince(last) >= 0.25, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        last = Date()
        onFaces?(FaceEngine.faces(in: CIImage(cvPixelBuffer: buffer)))
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

@Observable final class CameraModel {
    @ObservationIgnored let camera = PhoneCamera()
    var faces: [FaceHit] = []
    var front = false

    func start() {
        camera.onFaces = { [weak self] hits in DispatchQueue.main.async { self?.faces = hits } }
        camera.start(front: front)
    }

    func flip() {
        front.toggle()
        camera.start(front: front)
    }

    func stop() { camera.stop() }
}
