import Foundation
import CoreImage
import Vision

let ctx = CIContext()

func embed(_ cg: CGImage) -> [Float]? {
    let r = VNGenerateImageFeaturePrintRequest()
    r.imageCropAndScaleOption = .scaleFill
    try? VNImageRequestHandler(cgImage: cg).perform([r])
    guard let p = r.results?.first, p.elementType == .float else { return nil }
    var v = p.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
    guard n > 0 else { return nil }
    for i in v.indices { v[i] /= n }
    return v
}

struct Hit { let emb: [Float]; let sidePx: CGFloat; let frac: CGFloat }

func hits(_ url: URL) -> (detected: Int, hits: [Hit], w: CGFloat, h: CGFloat) {
    guard let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return (0, [], 0, 0) }
    let extent = img.extent
    let d = VNDetectFaceRectanglesRequest()
    try? VNImageRequestHandler(ciImage: img).perform([d])
    let faces = (d.results ?? []).sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
    var out: [Hit] = []
    for f in faces {
        let box = VNImageRectForNormalizedRect(f.boundingBox, Int(extent.width), Int(extent.height)).offsetBy(dx: extent.minX, dy: extent.minY)
        let c = CGPoint(x: box.midX, y: box.midY)
        var src = img
        let roll = CGFloat(f.roll?.doubleValue ?? 0)
        if abs(roll) > 0.01 {
            src = img.transformed(by: CGAffineTransform(translationX: c.x, y: c.y).rotated(by: -roll).translatedBy(x: -c.x, y: -c.y))
        }
        let side = max(box.width, box.height) * 1.25
        let sq = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side).intersection(src.extent)
        guard sq.width >= 40, let cg = ctx.createCGImage(src, from: sq), let e = embed(cg) else { continue }
        out.append(Hit(emb: e, sidePx: sq.width, frac: (box.width * box.height) / (extent.width * extent.height)))
    }
    return (faces.count, out, extent.width, extent.height)
}

func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    .filter { $0.lowercased().hasSuffix(".jpg") || $0.lowercased().hasSuffix(".jpeg") || $0.lowercased().hasSuffix(".png") }
    .sorted()

struct Photo { let id: String; let file: String; let detected: Int; let hits: [Hit] }
var photos: [Photo] = []
for f in files {
    let id = String(f.prefix(while: { $0 != "_" }))
    let r = hits(dir.appendingPathComponent(f))
    photos.append(Photo(id: id, file: f, detected: r.detected, hits: r.hits))
    let sides = r.hits.map { "\(Int($0.sidePx))px/\(String(format: "%.1f", Double($0.frac) * 100))%" }.joined(separator: " ")
    print("PHOTO \(f) img=\(Int(r.w))x\(Int(r.h)) detected=\(r.detected) embedded=\(r.hits.count) [\(sides)]")
}

// Gallery exactly as Store.loadReferences builds it: the LARGEST face of each photo.
var gallery: [String: [[Float]]] = [:]
for p in photos { if let first = p.hits.first { gallery[p.id, default: []].append(first.emb) } }
print("GALLERY " + gallery.map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " "))

let ids = gallery.keys.sorted()
print("--- leave-one-out: each photo's largest face probed against the gallery ---")
for (pi, p) in photos.enumerated() {
    guard let probe = p.hits.first else { continue }
    var scores: [(String, Float)] = []
    for id in ids {
        var best: Float = -1
        for (qi, q) in photos.enumerated() where q.id == id && qi != pi {
            if let e = q.hits.first { best = max(best, dot(probe.emb, e.emb)) }
        }
        if best > -1 { scores.append((id, best)) }
    }
    scores.sort { $0.1 > $1.1 }
    let top = scores.first, second = scores.dropFirst().first
    let gap = (top?.1 ?? 0) - (second?.1 ?? 0)
    let ok = (top?.0 == p.id) && (top?.1 ?? 0) >= 0.72 && gap >= 0.05
    print("PROBE \(p.file) truth=\(p.id) top=\(top?.0 ?? "-"):\(String(format: "%.3f", top?.1 ?? 0)) second=\(second?.0 ?? "-"):\(String(format: "%.3f", second?.1 ?? 0)) gap=\(String(format: "%.3f", gap)) \(ok ? "PASS" : "FAIL")")
}

print("--- every detected face in each photo, best-matching person ---")
for (pi, p) in photos.enumerated() {
    for (hi, h) in p.hits.enumerated() {
        var scores: [(String, Float)] = []
        for id in ids {
            var best: Float = -1
            for (qi, q) in photos.enumerated() where q.id == id && qi != pi {
                if let e = q.hits.first { best = max(best, dot(h.emb, e.emb)) }
            }
            scores.append((id, best))
        }
        scores.sort { $0.1 > $1.1 }
        let line = scores.prefix(3).map { "\($0.0):\(String(format: "%.3f", $0.1))" }.joined(separator: " ")
        print("FACE \(p.file)#\(hi) side=\(Int(h.sidePx))px \(line)")
    }
}

// Run it:  swift tools/refcheck.swift App/References
// It prints, per photo: how many faces Vision found, how big the one that gets embedded is, and
// then a leave-one-out identification of every photo against everyone else's. A person whose
// worst gap is under ~0.10 will not survive auto-identify on a live camera frame; give them more
// photos (different angle, light, distance) and run this again.
