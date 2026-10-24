import Accelerate
import UIKit

/// Writes every stream frame to disk exactly as it arrived, so settings can be compared side by
/// side instead of argued about. One folder per camera (`Documents/frames/<time>_<res>-<fps>`):
/// a new camera means new settings, so a run never mixes two of them.
///
/// Each run has a `frames.csv` with arrival time, the size the link actually delivered and a
/// sharpness score. The score is measured on a 360-wide copy of every frame, the low preset's
/// width, so a 720p frame that the link compressed into mush scores like mush instead of getting
/// credit for its pixel count.
///
/// Called from the SDK's publisher thread; encoding runs on its own queue so the stream never waits.
final class FrameRecorder: @unchecked Sendable {
    static let shared = FrameRecorder()
    static let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("frames", isDirectory: true)
    /// About 30 s at 30 fps, or 2 min at 7. A 720p frame is ~150 KB, so a full run is ~135 MB.
    static let cap = 900

    private let queue = DispatchQueue(label: "frame-recorder", qos: .utility)
    private let lock = NSLock()
    private var dir: URL?
    private var count = 0
    private var started = CFAbsoluteTimeGetCurrent()

    var isRecording: Bool { lock.withLock { dir != nil } }

    /// Starts a new run, ending any current one. `label` is what was asked for, e.g. "medium-15".
    func start(label: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let run = Self.root.appendingPathComponent("\(formatter.string(from: Date()))_\(label)", isDirectory: true)
        try? FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try? "seq,ms,width,height,sharpness,file\n".write(to: run.appendingPathComponent("frames.csv"), atomically: true, encoding: .utf8)
        lock.withLock {
            dir = run
            count = 0
            started = CFAbsoluteTimeGetCurrent()
        }
    }

    func stop() {
        lock.withLock { dir = nil }
    }

    func save(_ image: UIImage) {
        let slot: (dir: URL, seq: Int, ms: Int)? = lock.withLock {
            guard let dir, count < Self.cap else { return nil }
            count += 1
            return (dir, count, Int((CFAbsoluteTimeGetCurrent() - started) * 1000))
        }
        guard let slot else { return }
        queue.async {
            guard let cg = image.cgImage, let jpeg = image.jpegData(compressionQuality: 0.95) else { return }
            let name = String(format: "%04d.jpg", slot.seq)
            try? jpeg.write(to: slot.dir.appendingPathComponent(name))
            let line = "\(slot.seq),\(slot.ms),\(cg.width),\(cg.height),\(String(format: "%.4f", Self.sharpness(cg))),\(name)\n"
            guard let handle = try? FileHandle(forWritingTo: slot.dir.appendingPathComponent("frames.csv")) else { return }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }

    /// RMS Laplacian over a 360-wide grey copy, divided by the copy's contrast: a blur measure
    /// that a dim scene doesn't fail. The same idea as `FaceEngine.sharpness`, at frame scale.
    static func sharpness(_ image: CGImage) -> Float {
        let w = 360
        let h = max(3, Int(Double(image.height) * Double(w) / Double(max(image.width, 1))))
        var bytes = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return 0 }

        var pixels = [Float](repeating: 0, count: w * h)
        vDSP.convertElements(of: bytes, to: &pixels)
        var mean: Float = 0, deviation: Float = 0
        vDSP_normalize(pixels, 1, nil, 1, &mean, &deviation, vDSP_Length(w * h))
        guard deviation > 1 else { return 0 }

        var energy: Float = 0
        pixels.withUnsafeBufferPointer { p in
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let i = y * w + x
                    let lap = 4 * p[i] - p[i - 1] - p[i + 1] - p[i - w] - p[i + w]
                    energy += lap * lap
                }
            }
        }
        return sqrt(energy / Float((w - 2) * (h - 2))) / deviation
    }
}

/// One recorded run, read back from its folder.
struct FrameRun: Identifiable, Hashable {
    struct Frame: Identifiable, Hashable {
        let seq: Int
        let ms: Int
        let width: Int
        let height: Int
        let sharpness: Float
        let url: URL
        var id: Int { seq }
        var size: String { "\(width)x\(height)" }
    }

    let url: URL
    let frames: [Frame]
    var id: URL { url }
    var name: String { url.lastPathComponent }
    /// The settings that were asked for, from the folder name: "medium-15".
    var asked: String { name.split(separator: "_").last.map(String.init) ?? name }

    /// Frames over the time between the first and the last one: what the link really delivered.
    var fps: Double {
        guard let first = frames.first, let last = frames.last, last.ms > first.ms else { return 0 }
        return Double(frames.count - 1) / (Double(last.ms - first.ms) / 1000)
    }

    var medianSharpness: Float {
        let sorted = frames.map(\.sharpness).sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// "504x896 ×120, 360x640 ×8": every size the link sent, most common first.
    var sizes: String {
        Dictionary(grouping: frames, by: \.size)
            .sorted { $0.value.count > $1.value.count }
            .map { "\($0.key) ×\($0.value.count)" }
            .joined(separator: ", ")
    }

    static func all() -> [FrameRun] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: FrameRecorder.root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap(load).sorted { $0.name > $1.name }
    }

    static func load(_ url: URL) -> FrameRun? {
        guard let csv = try? String(contentsOf: url.appendingPathComponent("frames.csv"), encoding: .utf8) else { return nil }
        let frames = csv.split(separator: "\n").dropFirst().compactMap { line -> Frame? in
            let f = line.split(separator: ",")
            guard f.count == 6, let seq = Int(f[0]), let ms = Int(f[1]), let w = Int(f[2]),
                  let h = Int(f[3]), let sharp = Float(f[4]) else { return nil }
            return Frame(seq: seq, ms: ms, width: w, height: h, sharpness: sharp, url: url.appendingPathComponent(String(f[5])))
        }
        return FrameRun(url: url, frames: frames.sorted { $0.seq < $1.seq })
    }
}
