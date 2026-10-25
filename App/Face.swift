import Accelerate
import AVFoundation
import CoreML
import CoreVideo
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
    /// True when the detector gave us the keypoints and the crop is canonically aligned.
    let aligned: Bool
    /// How much this look should count as evidence, 0.35-1: small or turned faces embed worse,
    /// so the tracker weighs them less instead of letting them drag a fused probe around.
    var quality: Float = 1
    /// How likely this is the face the wearer is looking at: big, near the middle of the view,
    /// facing the camera. The glasses camera points where the head points, so the person you
    /// turned to is central and close; a crowd behind them is small and off to the side.
    var attention: Float = 0

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
    /// 112 px, not 160 or 224: measured EER 7.4% at 112 against 10.5% at 160 and 11.5% at 224 on
    /// the real references. It is also exactly what the ArcFace-family models expect.
    static let canonical: CGFloat = 112

    // MARK: Quality gate

    /// Below this the crop is not embedded at all. Measured: a *small sharp* face reaches d' 2.73
    /// while a *large blurry* one manages 0.54, so blur — not size — is what has to be rejected.
    /// Live-tunable: `minSharpness` in tuning.json.
    /// Default OFF (0). In simulation the gate never bound — live-frame sharpness sat at p10 0.25
    /// against a 0.10 gate — and a gate calibrated on simulated blur could silence a real demo.
    /// `streamStats` now logs the real p10/p50 from the glasses; set this from those numbers.
    static var minSharpness: Float { Tuning.float("minSharpness", 0) }
    /// Reference photos are enrolled unconditionally; a gate there would silently empty a gallery.
    static let enrolSharpness: Float = 0

    /// Which faces get looked at first when there are more than `limit`.
    enum Rank {
        /// Biggest first. Enrolment: the subject of a reference photo is the big face, even when
        /// the hall behind them scores higher (several references are shot on the hackathon floor).
        case largest
        /// Most likely to be the person the wearer is facing first. Live frames.
        case attention
    }

    /// SCRFD when its model is bundled (and `useSCRFD` isn't switched off), Vision otherwise.
    static var usingSCRFD: Bool { SCRFD.model != nil && Tuning.bool("useSCRFD", true) }
    static var detectorName: String { usingSCRFD ? "scrfd-500m" : "vision" }

    /// Apple's "how good a photo of this face is" (blur, light, pose, expression, anything in
    /// front of it), 0-1, for the largest face in `image`; nil when Vision finds no face at all.
    /// Only comparable between photos of the same person. Measured on App/References: blur takes
    /// ~0.4 to under 0.1, a hand over the mouth ~0.45 to ~0.33; a band over the eyes barely moves it.
    static func captureQuality(_ image: CGImage) -> Float? {
        let request = VNDetectFaceCaptureQualityRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.max { $0.boundingBox.width < $1.boundingBox.width }?.faceCaptureQuality
    }

    /// Live faces narrower than this (px in the frame) are not embedded or tracked. ArcFace on a
    /// 25 px face is close to noise, and on the hackathon floor every frame has a dozen of them in
    /// the background: they cost time and are the likeliest source of a stranger matching someone.
    static var minFacePx: CGFloat { CGFloat(Tuning.float("minFacePx", 32)) }

    /// Detects faces (largest first) and embeds each one. Kept for the enrolment path.
    static func faces(in image: CIImage, limit: Int = .max) -> [FaceHit] {
        scan(image, limit: limit, minSharpness: enrolSharpness).hits
    }

    /// Detection runs on every face; the first `limit` by `rank` are cropped, and of those only the
    /// ones sharp enough to be worth embedding are. Blurred faces come back with an empty embedding.
    static func scan(_ image: CIImage, limit: Int = .max, minSharpness: Float? = nil,
                     rank: Rank = .largest, minFace: CGFloat = 24) -> (hits: [FaceHit], timing: FaceTiming) {
        let gate = minSharpness ?? self.minSharpness
        var timing = FaceTiming()
        var start = CFAbsoluteTimeGetCurrent()
        let found = detect(image).filter { $0.box.width >= minFace && $0.box.height >= minFace }
        timing.detectMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        timing.faces = found.count

        let ordered: [Found]
        switch rank {
        case .largest: ordered = found.sorted { $0.box.width * $0.box.height > $1.box.width * $1.box.height }
        case .attention: ordered = found.sorted { $0.attention > $1.attention }
        }

        // Crop and score quality first — cheap — so the expensive embed only runs on what can win.
        let candidates = ordered.prefix(limit).compactMap { crop(image, $0) }
        start = CFAbsoluteTimeGetCurrent()
        var hits: [FaceHit] = []
        hits.reserveCapacity(candidates.count)
        for candidate in candidates {
            timing.bestSharpness = max(timing.bestSharpness, candidate.sharpness)
            guard candidate.sharpness >= gate else {
                timing.gated += 1
                hits.append(FaceHit(embedding: [], crop: candidate.image, area: candidate.area,
                                    box: candidate.box, sharpness: candidate.sharpness,
                                    aligned: candidate.aligned, quality: candidate.quality,
                                    attention: candidate.attention))
                continue
            }
            guard let embedding = embed(candidate.image) else { continue }
            hits.append(FaceHit(embedding: embedding, crop: candidate.image, area: candidate.area,
                                box: candidate.box, sharpness: candidate.sharpness,
                                aligned: candidate.aligned, quality: candidate.quality,
                                attention: candidate.attention))
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
        let quality: Float
        let attention: Float
    }

    // MARK: Detection

    /// A face before cropping, from either detector.
    private struct Found {
        /// Image coordinates, y-up.
        let box: CGRect
        /// 0-1 within the frame, y-up — the same convention as Vision's `boundingBox`.
        let normalized: CGRect
        /// Keypoints and where they belong in the canonical face, when the detector gave them.
        let pairs: (source: [CGPoint], target: [CGPoint])?
        let roll: CGFloat
        /// 1 facing the camera, down to 0.3 in profile.
        let frontal: Float
        let attention: Float
        let quality: Float
    }

    private static func detect(_ image: CIImage) -> [Found] {
        let extent = image.extent
        func found(box: CGRect, pairs: (source: [CGPoint], target: [CGPoint])?, roll: CGFloat, frontal: Float) -> Found {
            let normalized = CGRect(x: (box.minX - extent.minX) / extent.width,
                                    y: (box.minY - extent.minY) / extent.height,
                                    width: box.width / extent.width, height: box.height / extent.height)
            // Gaussian falloff from the middle of the view, a little looser vertically: the camera
            // sits above the eyes, so the face you look at lands slightly high in the frame.
            let dx = Float(normalized.midX - 0.5), dy = Float(normalized.midY - 0.55)
            let centrality = exp(-(dx * dx) / (2 * 0.22 * 0.22) - (dy * dy) / (2 * 0.3 * 0.3))
            let size = Float(min(1, normalized.width / 0.25))
            let attention = sqrt(size) * centrality * frontal
            let quality = max(0.35, min(1, Float((box.width - 24) / 32))) * frontal
            return Found(box: box, normalized: normalized, pairs: pairs, roll: roll,
                         frontal: frontal, attention: attention, quality: quality)
        }

        if usingSCRFD, let detections = SCRFD.detect(image, context: context, threshold: Tuning.float("detScore", 0.5)) {
            return detections.map { d in
                let p = d.points
                // Order by screen x, never by which side of the head it is (see landmarkPairs).
                let eyes = p[0].x <= p[1].x ? [p[0], p[1]] : [p[1], p[0]]
                let mouth = p[3].x <= p[4].x ? [p[3], p[4]] : [p[4], p[3]]
                let eyeGap = max(hypot(eyes[1].x - eyes[0].x, eyes[1].y - eyes[0].y), 1)
                // Yaw: how far the nose sits off the line between the eyes, in eye-gaps. ~0 facing
                // the camera, ~0.5 well turned.
                let yaw = Float(abs(p[2].x - (eyes[0].x + eyes[1].x) / 2) / eyeGap)
                let frontal = max(0.3, min(1, 1.15 - 1.5 * yaw))
                let roll = atan2(eyes[1].y - eyes[0].y, eyes[1].x - eyes[0].x)
                return found(box: d.box,
                             pairs: (eyes + [p[2]] + mouth, [eyeLeft, eyeRight, noseTip, mouthLeft, mouthRight]),
                             roll: roll, frontal: frontal)
            }
        }

        // Vision. Landmarks, not just rectangles: the eye centres are what let us put every face
        // into one canonical pose. The request also carries the bounding box and roll.
        let wantAlignment = Tuning.bool("alignFaces", true)
        let request: VNImageBasedRequest = wantAlignment ? VNDetectFaceLandmarksRequest() : VNDetectFaceRectanglesRequest()
        onSimulatorCPU(request)
        try? VNImageRequestHandler(ciImage: image).perform([request])
        let observations = ((request as? VNDetectFaceLandmarksRequest)?.results
            ?? (request as? VNDetectFaceRectanglesRequest)?.results ?? [])
        return observations.map { face in
            let box = VNImageRectForNormalizedRect(face.boundingBox, Int(extent.width), Int(extent.height))
                .offsetBy(dx: extent.minX, dy: extent.minY)
            let yaw = Float(abs(face.yaw?.doubleValue ?? 0))   // radians, 0 facing the camera
            return found(box: box, pairs: wantAlignment ? landmarkPairs(image, face) : nil,
                         roll: CGFloat(face.roll?.doubleValue ?? 0),
                         frontal: max(0.3, min(1, 1.2 - yaw)))
        }
    }

    // MARK: Alignment

    /// The canonical ArcFace five-point template (112x112, origin top-left), flipped into the
    /// y-up space Vision and CoreImage work in. Every face — bundled reference and live frame —
    /// is mapped onto these coordinates, which is what makes two pictures of the same person
    /// comparable at all.
    private static func templatePoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: canonical - y) }
    private static let eyeLeft = templatePoint(38.2946, 51.6963)
    private static let eyeRight = templatePoint(73.5318, 51.5014)
    private static let noseTip = templatePoint(56.0252, 71.7366)
    private static let mouthLeft = templatePoint(41.5493, 92.3655)
    private static let mouthRight = templatePoint(70.7299, 92.2041)

    /// Cuts the face out of the frame into the canonical space.
    ///
    /// 1. **Alignment.** Eye centres, nose tip and mouth corners are mapped onto the template by a
    ///    least-squares similarity transform. Measured across four landmark choices on the real
    ///    references: this one (eye centroids + nose tip + lip corners) is the best — 43/43
    ///    leave-one-out, median margin 0.907, and it beats using Vision's pupils. Without the nose
    ///    point it drops to 42/43. When landmarks are missing we fall back to de-rolling about the
    ///    face centre, which is what this did before.
    /// 2. **The square is never clipped.** It used to be `.intersection(extent)`, which for a face
    ///    near the edge of the frame returns a *non-square* rect; `.scaleFill` then stretched it
    ///    and the face was embedded in a distorted space it could never match from. Clamping the
    ///    source instead keeps every crop square — an edge face gets edge pixels, not a squash.
    private static func crop(_ image: CIImage, _ face: Found) -> Candidate? {
        let box = face.box
        // Both dimensions, not just width: a box clipped to 10 px tall used to sail through.
        guard box.width >= 24, box.height >= 24 else { return nil }

        if Tuning.bool("alignFaces", true),
           let pairs = face.pairs,
           let transform = similarity(from: pairs.source, to: pairs.target),
           let cg = context.createCGImage(image.clampedToExtent().transformed(by: transform),
                                          from: CGRect(x: 0, y: 0, width: canonical, height: canonical)) {
            return Candidate(image: cg, area: box.width * box.height, box: face.normalized,
                             sharpness: sharpness(cg), aligned: true,
                             quality: face.quality, attention: face.attention)
        }

        // Fallback: de-roll about the face's own centre, which leaves that centre in place.
        let centre = CGPoint(x: box.midX, y: box.midY)
        var source = image
        let roll = face.roll
        if abs(roll) > 0.01 {
            source = image.transformed(by: CGAffineTransform(translationX: centre.x, y: centre.y)
                .rotated(by: -roll)
                .translatedBy(x: -centre.x, y: -centre.y))
        }
        let side = max(box.width, box.height) * 1.25
        let square = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
        guard let cg = context.createCGImage(source.clampedToExtent(), from: square) else { return nil }
        return Candidate(image: cg, area: box.width * box.height, box: face.normalized,
                         sharpness: sharpness(cg), aligned: false,
                         quality: face.quality * 0.7, attention: face.attention)
    }

    /// Landmarks paired with where they belong in the canonical face.
    private static func landmarkPairs(_ image: CIImage, _ face: VNFaceObservation) -> (source: [CGPoint], target: [CGPoint])? {
        guard let marks = face.landmarks else { return nil }
        let size = CGSize(width: image.extent.width, height: image.extent.height)
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let region else { return [] }
            return region.pointsInImage(imageSize: size)
                .map { CGPoint(x: $0.x + image.extent.minX, y: $0.y + image.extent.minY) }
        }
        func centre(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            let all = points(region)
            guard !all.isEmpty else { return nil }
            var x: CGFloat = 0, y: CGFloat = 0
            for p in all { x += p.x; y += p.y }
            return CGPoint(x: x / CGFloat(all.count), y: y / CGFloat(all.count))
        }
        guard let a = centre(marks.leftEye), let b = centre(marks.rightEye) else { return nil }
        let lips = points(marks.outerLips)
        guard let m1 = lips.min(by: { $0.x < $1.x }), let m2 = lips.max(by: { $0.x < $1.x }) else { return nil }
        // Order by screen x, never by which side of the head it is: that way a mirrored or
        // turned face can never flip the transform.
        let eyes = a.x <= b.x ? [a, b] : [b, a]
        let mouth = m1.x <= m2.x ? [m1, m2] : [m2, m1]
        guard let tip = points(marks.nose).min(by: { $0.y < $1.y }) else {
            return (eyes + mouth, [eyeLeft, eyeRight, mouthLeft, mouthRight])
        }
        return (eyes + [tip] + mouth, [eyeLeft, eyeRight, noseTip, mouthLeft, mouthRight])
    }

    /// Least-squares 2D similarity (uniform scale + rotation + translation) in closed form.
    /// No reflection term, deliberately: a face must never be solved by mirroring it.
    private static func similarity(from source: [CGPoint], to target: [CGPoint]) -> CGAffineTransform? {
        guard source.count == target.count, source.count >= 2 else { return nil }
        let n = CGFloat(source.count)
        let ms = CGPoint(x: source.reduce(0) { $0 + $1.x } / n, y: source.reduce(0) { $0 + $1.y } / n)
        let mt = CGPoint(x: target.reduce(0) { $0 + $1.x } / n, y: target.reduce(0) { $0 + $1.y } / n)
        var na: CGFloat = 0, nb: CGFloat = 0, den: CGFloat = 0
        for i in source.indices {
            let sx = source[i].x - ms.x, sy = source[i].y - ms.y
            let tx = target[i].x - mt.x, ty = target[i].y - mt.y
            na += sx * tx + sy * ty
            nb += sx * ty - sy * tx
            den += sx * sx + sy * sy
        }
        guard den > 0.0001 else { return nil }
        let a = na / den, b = nb / den
        guard a.isFinite, b.isFinite, a * a + b * b > 1e-12 else { return nil }
        return CGAffineTransform(a: a, b: b, c: -b, d: a,
                                 tx: mt.x - (a * ms.x - b * ms.y),
                                 ty: mt.y - (b * ms.x + a * ms.y))
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

    // MARK: The embedder

    /// What turns a face crop into a vector.
    ///
    /// `VNGenerateImageFeaturePrintRequest` is a general perceptual-image descriptor, not a face
    /// model: it encodes sharpness, lighting and background about as strongly as identity. On the
    /// real glasses it was scoring the right person 0.861 with the runner-up at 0.859 — a margin
    /// of 0.002, which is a coin toss, and the gate correctly refused to name anybody.
    ///
    /// The bundled MobileFaceNet (ArcFace, 512-d, trained on WebFace600K) is a face model. On the
    /// same 43 photos, in the same decision loop, on simulated glasses frames: 42/43 walk-ups
    /// answered with 0 wrong against 28/43, and the median margin goes 0.222 -> 0.907.
    ///
    /// **Licence: the weights are non-commercial research use only.** Fine for a demo, not for a
    /// product without retraining. The model is deliberately NOT in the public GitHub mirror.
    ///
    /// It is loaded by file, not through a generated class, so the app still builds and runs when
    /// the model is absent — it just falls back to the feature print and says so in the log.
    enum Embedder {
        case arcFace(MLModel)
        case featurePrint

        var name: String {
            if case .arcFace = self { return "arcface-mbf" }
            return "vision-featureprint"
        }
        /// Defaults for `minScore`/`minGap`. The two embeddings do not share a scale at all:
        /// feature-print cosines sit at 0.6-0.9 for everyone, ArcFace at ~0.4 for the same person
        /// and ~0.0 for anybody else.
        var minScore: Float {
            if case .arcFace = self { return 0.33 }
            return 0.72
        }
        var minGap: Float {
            if case .arcFace = self { return 0.10 }
            return 0.05
        }
    }

    static let embedder: Embedder = {
        guard Tuning.bool("useArcFace", true),
              let url = Bundle.main.url(forResource: "MobileFaceNet_w600k", withExtension: "mlmodelc") else {
            SpeedLog.record(["event": "embedder", "using": "vision-featureprint", "reason": "noModelInBundle"])
            return .featurePrint
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let model = try? MLModel(contentsOf: url, configuration: configuration) else {
            SpeedLog.record(["event": "embedder", "using": "vision-featureprint", "reason": "modelLoadFailed"])
            return .featurePrint
        }
        SpeedLog.record(["event": "embedder", "using": "arcface-mbf"])
        return .arcFace(model)
    }()

    /// Loads the models up front so the first identify doesn't pay for it.
    /// Vision in the iOS Simulator fails every request with "Could not create inference context"
    /// unless it is pinned to the CPU (the simulator GPU fails the same way), so a replay there saw
    /// no faces at all. Even on the CPU the landmarks never come back, so simulator crops are never
    /// aligned and its matches differ from a phone's: watch replays there, measure them on a phone.
    static func onSimulatorCPU(_ request: VNRequest) {
        #if targetEnvironment(simulator)
        guard let cpu = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { true } else { false } }),
              let stages = try? request.supportedComputeStageDevices else { return }
        for stage in stages.keys { request.setComputeDevice(cpu, for: stage) }
        #endif
    }

    static func warmUp() {
        let blank = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
        try? VNImageRequestHandler(ciImage: blank).perform([VNDetectFaceLandmarksRequest()])
        _ = SCRFD.detect(blank, context: context)
        SpeedLog.record(["event": "detector", "using": detectorName])
        if let cg = context.createCGImage(blank, from: blank.extent) { _ = embed(cg) }
    }

    static func embed(_ image: CGImage) -> [Float]? {
        switch embedder {
        case .arcFace(let model): return arcFace(image, model) ?? featurePrint(image)
        case .featurePrint: return featurePrint(image)
        }
    }

    private static func arcFace(_ image: CGImage, _ model: MLModel) -> [Float]? {
        guard let buffer = pixelBuffer(image),
              let input = try? MLDictionaryFeatureProvider(dictionary: ["face": MLFeatureValue(pixelBuffer: buffer)]),
              let output = try? model.prediction(from: input),
              let array = output.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        var v = [Float](repeating: 0, count: array.count)
        let source = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        for i in 0..<array.count { v[i] = source[i] }
        return normalised(v)
    }

    /// 112x112 BGRA. The model's own scale and bias (pixel/127.5 - 1) are baked into it, so the
    /// pixels go in untouched — normalising here as well would quietly halve the contrast.
    private static func pixelBuffer(_ image: CGImage) -> CVPixelBuffer? {
        let side = Int(canonical)
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true,
                          kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let pixels = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        guard let cg = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: side, height: side,
                                 bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        cg.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels
    }

    private static func featurePrint(_ image: CGImage) -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        onSimulatorCPU(request)
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let print = request.results?.first, print.elementType == .float else { return nil }
        return normalised(print.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
    }

    private static func normalised(_ vector: [Float]) -> [Float]? {
        var v = vector
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
