import Accelerate
import CoreImage
import CoreML
import CoreVideo
import Foundation

/// SCRFD-500M, the face detector from InsightFace, run through Core ML.
///
/// Why not Vision: on the 43 references shrunk to glasses-at-distance sizes in a 504x896 frame,
/// Vision found 70% of 24 px faces, 81-84% at 48-64 px, and 2% of blurred 24 px faces. SCRFD-500M
/// found 88%, 100% and 79%, at the same ~6 ms. It also returns the five keypoints the ArcFace
/// embedder was trained to be aligned by, instead of an approximation built from Vision's contours.
///
/// The input is fixed at 512x896 portrait, i.e. a glasses frame (504x896) with 8 px of padding and
/// no downscaling at all, so a small face keeps every pixel it has. Anything else is letterboxed in.
///
/// **Licence: the weights are non-commercial research use only**, like the embedder. The model is
/// gitignored (App/*.mlpackage); without it `FaceEngine` falls back to Vision and says so.
enum SCRFD {
    struct Detection {
        /// Image coordinates, y-up (CoreImage space), in the source image's own extent.
        var box: CGRect
        /// Left eye, right eye, nose tip, left mouth corner, right mouth corner — "left" meaning
        /// left in the picture. Same space as `box`.
        var points: [CGPoint]
        var score: Float
    }

    static let width = 512
    static let height = 896
    private static let strides = [8, 16, 32]
    private static let anchorsPerCell = 2

    static let model: MLModel? = {
        guard let url = Bundle.main.url(forResource: "SCRFD_500M", withExtension: "mlmodelc") else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return try? MLModel(contentsOf: url, configuration: configuration)
    }()

    private static var pool: CVPixelBufferPool? = {
        var pool: CVPixelBufferPool?
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                           kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                                           kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        return pool
    }()
    private static let black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))

    /// Faces in `image`, highest score first, or nil when the model isn't available.
    static func detect(_ image: CIImage, context: CIContext, threshold: Float = 0.5, nms: CGFloat = 0.4) -> [Detection]? {
        guard let model, let pool else { return nil }
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return [] }

        // Letterbox at the top-left: SCRFD is resolution-free, so padding never costs accuracy.
        let scale = min(CGFloat(width) / extent.width, CGFloat(height) / extent.height)
        let placed = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(height) - extent.height * scale))
            .composited(over: black)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        context.render(placed, to: buffer, bounds: black.extent, colorSpace: CGColorSpaceCreateDeviceRGB())

        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]),
              let output = try? model.prediction(from: input) else { return nil }

        var found: [Detection] = []
        for stride in strides {
            guard let scores = output.featureValue(for: "score_\(stride)")?.multiArrayValue,
                  let boxes = output.featureValue(for: "bbox_\(stride)")?.multiArrayValue,
                  let marks = output.featureValue(for: "kps_\(stride)")?.multiArrayValue else { continue }
            let s = read(scores), b = read(boxes), k = read(marks)
            let cols = width / stride
            let step = Float(stride)
            for i in 0..<s.count where s[i] >= threshold {
                // Anchors run row-major over the grid, two per cell, both centred on the cell corner.
                let cell = i / anchorsPerCell
                let cx = Float(cell % cols) * step, cy = Float(cell / cols) * step
                let x1 = cx - b[i * 4] * step, y1 = cy - b[i * 4 + 1] * step
                let x2 = cx + b[i * 4 + 2] * step, y2 = cy + b[i * 4 + 3] * step
                var points: [CGPoint] = []
                for p in 0..<5 {
                    points.append(toImage(cx + k[i * 10 + p * 2] * step, cy + k[i * 10 + p * 2 + 1] * step,
                                          scale: scale, extent: extent))
                }
                let a = toImage(x1, y2, scale: scale, extent: extent)   // bottom-left in y-up space
                let c = toImage(x2, y1, scale: scale, extent: extent)
                found.append(Detection(box: CGRect(x: a.x, y: a.y, width: c.x - a.x, height: c.y - a.y),
                                       points: points, score: s[i]))
            }
        }
        return suppress(found.sorted { $0.score > $1.score }, overlap: nms)
    }

    /// Model input pixels (y-down, letterboxed) back to the source image's y-up coordinates.
    private static func toImage(_ x: Float, _ y: Float, scale: CGFloat, extent: CGRect) -> CGPoint {
        CGPoint(x: extent.minX + CGFloat(x) / scale,
                y: extent.minY + extent.height - CGFloat(y) / scale)
    }

    /// Core ML hands back FP16 or FP32 depending on the compute unit, and pads each row (the
    /// Neural Engine output here is [N, 1] with a row stride of 32), so copy it out row by row
    /// into a dense [rows * cols] Float array.
    private static func read(_ array: MLMultiArray) -> [Float] {
        let rows = array.shape[0].intValue
        let cols = array.shape.count > 1 ? array.shape[1].intValue : 1
        let rowStride = array.strides[0].intValue
        let colStride = array.strides.count > 1 ? array.strides[1].intValue : 1
        var out = [Float](repeating: 0, count: rows * cols)
        func copy<T: MLShapedArrayScalar>(_ type: T.Type, _ convert: (T) -> Float) {
            array.withUnsafeBufferPointer(ofType: type) { src in
                for r in 0..<rows {
                    for c in 0..<cols { out[r * cols + c] = convert(src[r * rowStride + c * colStride]) }
                }
            }
        }
        switch array.dataType {
        case .float16: copy(Float16.self) { Float($0) }
        case .float32: copy(Float.self) { $0 }
        default:
            for r in 0..<rows { for c in 0..<cols { out[r * cols + c] = array[[r, c] as [NSNumber]].floatValue } }
        }
        return out
    }

    private static func suppress(_ sorted: [Detection], overlap: CGFloat) -> [Detection] {
        var keep: [Detection] = []
        for d in sorted where !keep.contains(where: { iou($0.box, d.box) > overlap }) { keep.append(d) }
        return keep
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        return i.width * i.height / (a.width * a.height + b.width * b.height - i.width * i.height)
    }
}
