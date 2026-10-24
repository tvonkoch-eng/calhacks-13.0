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

enum FaceEngine {
    private static let context = CIContext()

    /// Detects faces (largest first) and embeds each one with a Vision feature print.
    static func faces(in image: CIImage) -> [FaceHit] {
        let detect = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(ciImage: image).perform([detect])
        let extent = image.extent
        let hits: [FaceHit] = (detect.results ?? []).compactMap { face in
            let box = VNImageRectForNormalizedRect(face.boundingBox, Int(extent.width), Int(extent.height))
            let side = max(box.width, box.height) * 1.25
            let square = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
                .offsetBy(dx: extent.minX, dy: extent.minY)
                .intersection(extent)
            guard square.width >= 60,
                  let crop = context.createCGImage(image, from: square),
                  let embedding = embed(crop) else { return nil }
            return FaceHit(embedding: embedding, crop: crop, area: box.width * box.height)
        }
        return hits.sorted { $0.area > $1.area }
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
