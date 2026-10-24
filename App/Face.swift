import Accelerate
import AVFoundation
import CoreImage
import SwiftUI
import Vision

/// One face found in a frame: where it is, how good a look we got, its embedding, and a crop.
struct FaceHit {
    /// L2-normalised. **Empty when the crop failed the quality gate** — the face was still seen
    /// and can still be tracked, it just isn't evidence about who it is.
    let embedding: [Float]
    let crop: CGImage
    let area: CGFloat
    /// Normalised bounding box in the source frame, so a face can be followed between frames.
    let box: CGRect
    /// Contrast-normalised Laplacian energy of the crop at a fixed face-relative resolution:
    /// "how sharp is this face, as the embedder will see it". ~0.05 is mush, ~0.25 is crisp.
    let sharpness: Float
    /// True when Vision gave us both eyes and the crop is canonically aligned.
    let aligned: Bool

    var usable: Bool { !embedding.isEmpty }
}

/// Where the time went in one scan (milliseconds).
struct FaceTiming {
    var detectMs = 0.0
    var embedMs = 0.0
    var faces = 0
    /// Faces seen but not embedded because they were too blurry or too small.
    var gated = 0
    var bestSharpness: Float = 0
}

enum FaceEngine {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Canonical face size for the aligned crop. Both the bundled references and live frames go
    /// through this, so the gallery and the probe always live in the same space.
    static let canonical: CGFloat = 160

    // MARK: Quality gate

    /// Below this the crop is not embedded at all. Measured: a *small sharp* face reaches d' 2.73
    /// while a *large blurry* one manages 0.54, so blur — not size — is what has to be rejected.
    /// Live-tunable: `minSharpness` in tuning.json.
    static var minSharpness: Float { Tuning.float("minSharpness", 0.10) }
    /// Reference photos are enrolled unconditionally; a gate there would silently empty a gallery.
    static let enrolSharpness: Float = 0

    /// Detects faces (largest first) and embeds each one. Kept for the enrolment path.
    static func faces(in image: CIImage, limit: Int = .max) -> [FaceHit] {
        scan(image, limit: limit, minSharpness: enrolSharpness).hits
    }

    /// Detection runs on every face; the `limit` largest are cropped, and of those only the ones
    /// sharp enough to be worth 6 ms are embedded. Blurred faces come back with an empty embedding.
    static func scan(_ image: CIImage, limit: Int = .max, minSharpness: Float? = nil) -> (hits: [FaceHit], timing: FaceTiming) {
        let gate = minSharpness ?? self.minSharpness
        var timing = FaceTiming()
        var start = CFAbsoluteTimeGetCurrent()

        // Landmarks, not just rectangles: the eye centres are what let us put every face into one
        // canonical pose. The request also carries the bounding box and roll, so this replaces
        // VNDetectFaceRectanglesRequest rather than running alongside it.
        let wantAlignment = Tuning.bool("alignFaces", true)
        let request: VNImageBasedRequest = wantAlignment ? VNDetectFaceLandmarksRequest() : VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(ciImage: image).perform([request])
        let observations = ((request as? VNDetectFaceLandmarksRequest)?.results
            ?? (request as? VNDetectFaceRectanglesRequest)?.results ?? [])
        timing.detectMs = (CFAbsoluteTimeGetCurrent() - start) * 1000

        let faces = observations.sorted {
            $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height
        }
        timing.faces = faces.count

        // Crop and score quality first — cheap — so the expensive embed only runs on what can win.
        let candidates = faces.prefix(limit).compactMap { crop(image, $0) }
        start = CFAbsoluteTimeGetCurrent()
        var hits: [FaceHit] = []
        hits.reserveCapacity(candidates.count)
        for candidate in candidates {
            timing.bestSharpness = max(timing.bestSharpness, candidate.sharpness)
            guard candidate.sharpness >= gate else {
                timing.gated += 1
                hits.append(FaceHit(embedding: [], crop: candidate.image, area: candidate.area,
                                    box: candidate.box, sharpness: candidate.sharpness,
                                    aligned: candidate.aligned))
                continue
            }
            guard let embedding = embed(candidate.image) else { continue }
            hits.append(FaceHit(embedding: embedding, crop: candidate.image, area: candidate.area,
                                box: candidate.box, sharpness: candidate.sharpness,
                                aligned: candidate.aligned))
        }
        timing.embedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        return (hits, timing)
    }

    private struct Candidate {
        let image: CGImage
        let area: CGFloat
        let box: CGRect
        let sharpness: Float
        let aligned: Bool
    }

    /// Cuts the face out of the frame into the canonical space.
    ///
    /// Two things happen here, and both are about making the gallery and the live frame comparable:
    ///
    /// 1. **Alignment.** A feature print is a whole-image descriptor, so it compares a face in
    ///    whatever pose the pixels arrived in. When Vision gives us both eyes we map them onto a
    ///    fixed position in a square canvas — the standard similarity-transform alignment every
    ///    face model is trained on. Measured on the real references: EER 9.7% -> 7.0%, worst
    ///    genuine pair 0.587 -> 0.700, watch gate 86% -> 93% with no wrong names. When the eyes
    ///    aren't available we fall back to de-rolling about the face centre, which is what this
    ///    did before.
    /// 2. **The square is never clipped.** It used to be `.intersection(extent)`, which for a face
    ///    near the edge of the frame returns a *non-square* rect; `.scaleFill` then stretched it
    ///    and the face was embedded in a distorted space it could never match from. Clamping the
    ///    source instead keeps every crop square — an edge face gets edge pixels, not a squash.
    private static func crop(_ image: CIImage, _ face: VNFaceObservation) -> Candidate? {
        let extent = image.extent
        let box = VNImageRectForNormalizedRect(face.boundingBox, Int(extent.width), Int(extent.height))
            .offsetBy(dx: extent.minX, dy: extent.minY)
        // Both dimensions, not just width: a box clipped to 10 px tall used to sail through.
        guard box.width >= 24, box.height >= 24 else { return nil }
        let side = canonical

        if let eyes = eyeCentres(image, face) {
            let dx = eyes.right.x - eyes.left.x, dy = eyes.right.y - eyes.left.y
            let dist = sqrt(dx * dx + dy * dy)
            if dist > 4 {
                let mid = CGPoint(x: (eyes.left.x + eyes.right.x) / 2, y: (eyes.left.y + eyes.right.y) / 2)
                let scale = (side * 0.40) / dist
                var t = CGAffineTransform.identity
                    .translatedBy(x: side / 2, y: side * 0.62)
                    .scaledBy(x: scale, y: scale)
                    .rotated(by: -atan2(dy, dx))
                t = t.translatedBy(x: -mid.x, y: -mid.y)
                let square = CGRect(x: 0, y: 0, width: side, height: side)
                if let cg = context.createCGImage(image.clampedToExtent().transformed(by: t), from: square) {
                    return Candidate(image: cg, area: box.width * box.height,
                                     box: face.boundingBox, sharpness: sharpness(cg), aligned: true)
                }
            }
        }

        // Fallback: de-roll about the face's own centre, which leaves that centre in place.
        let centre = CGPoint(x: box.midX, y: box.midY)
        var source = image
        let roll = CGFloat(face.roll?.doubleValue ?? 0)
        if abs(roll) > 0.01 {
            source = image.transformed(by: CGAffineTransform(translationX: centre.x, y: centre.y)
                .rotated(by: -roll)
                .translatedBy(x: -centre.x, y: -centre.y))
        }
        let boxSide = max(box.width, box.height) * 1.25
        let square = CGRect(x: centre.x - boxSide / 2, y: centre.y - boxSide / 2, width: boxSide, height: boxSide)
        guard let cg = context.createCGImage(source.clampedToExtent(), from: square) else { return nil }
        return Candidate(image: cg, area: box.width * box.height,
                         box: face.boundingBox, sharpness: sharpness(cg), aligned: false)
    }

    private static func eyeCentres(_ image: CIImage, _ face: VNFaceObservation) -> (left: CGPoint, right: CGPoint)? {
        guard let landmarks = face.landmarks, let le = landmarks.leftEye, let re = landmarks.rightEye else { return nil }
        let size = CGSize(width: image.extent.width, height: image.extent.height)
        func centre(_ region: VNFaceLandmarkRegion2D) -> CGPoint? {
            let points = region.pointsInImage(imageSize: size)
            guard !points.isEmpty else { return nil }
            var x: CGFloat = 0, y: CGFloat = 0
            for p in points { x += p.x; y += p.y }
            return CGPoint(x: x / CGFloat(points.count) + image.extent.minX,
                           y: y / CGFloat(points.count) + image.extent.minY)
        }
        guard let a = centre(le), let b = centre(re) else { return nil }
        // "left"/"right" are the subject's; order them by screen x so the rotation never flips.
        return a.x <= b.x ? (a, b) : (b, a)
    }

    // MARK: Sharpness

    /// Variance of the Laplacian over a 48x48 grey version of the crop, divided by the crop's own
    /// contrast. Dividing is what makes it a *blur* measure rather than a contrast measure: a dim
    /// or flat face is not penalised, a smeared one is. Sampling at a fixed 48x48 makes it
    /// face-relative — exactly the thing that matters, since the embedder sees a rescaled crop too.
    static func sharpness(_ image: CGImage) -> Float {
        let n = 48
        var bytes = [UInt8](repeating: 0, count: n * n)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return 0 }

        var pixels = [Float](repeating: 0, count: n * n)
        vDSP.convertElements(of: bytes, to: &pixels)
        var mean: Float = 0, deviation: Float = 0
        vDSP_normalize(pixels, 1, nil, 1, &mean, &deviation, vDSP_Length(n * n))
        guard deviation > 1 else { return 0 }

        var energy: Float = 0
        var count: Float = 0
        for y in 1..<(n - 1) {
            for x in 1..<(n - 1) {
                let i = y * n + x
                let lap = 4 * pixels[i] - pixels[i - 1] - pixels[i + 1] - pixels[i - n] - pixels[i + n]
                energy += lap * lap
                count += 1
            }
        }
        return sqrt(energy / max(count, 1)) / deviation
    }

    // MARK: Embedding

    /// Loads the Vision models up front so the first identify doesn't pay for it.
    static func warmUp() {
        let blank = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
        let handler = VNImageRequestHandler(ciImage: blank)
        try? handler.perform([VNDetectFaceLandmarksRequest(), VNDetectFaceRectanglesRequest()])
        if let cg = context.createCGImage(blank, from: blank.extent) { _ = embed(cg) }
    }

    static func embed(_ image: CGImage) -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let print = request.results?.first, print.elementType == .float else { return nil }
        var v = print.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = sqrt(norm)
        guard norm > 0 else { return nil }
        var scale = 1 / norm
        vDSP_vsmul(v, 1, &scale, &v, 1, vDSP_Length(v.count))
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
