import Foundation
import CoreImage
import Accelerate
let det = CommandLine.arguments[1], refs = CommandLine.arguments[2]
let gt = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: det + "/gt.json"))) as! [String: [Double]]
func load(_ p: String, maxSide: CGFloat = 1600) -> CIImage {
    var i = CIImage(contentsOf: URL(fileURLWithPath: p), options: [.applyOrientationProperty: true])!
    let s = min(1, maxSide / max(i.extent.width, i.extent.height))
    if s < 1 { i = i.transformed(by: CGAffineTransform(scaleX: s, y: s)) }
    return i
}
// gallery: one embedding per reference photo (largest face), keyed by file
var gallery: [(file: String, person: String, e: [Float])] = []
for f in try! FileManager.default.contentsOfDirectory(atPath: refs).filter({ $0.hasSuffix(".jpg") }).sorted() {
    guard let h = FaceEngine.faces(in: load(refs + "/" + f)).first, h.usable else { print("no ref face", f); continue }
    gallery.append((f, String(f.split(separator: "_")[0]), h.embedding))
}
func dot(_ a: [Float], _ b: [Float]) -> Float { var s: Float = 0; vDSP_dotpr(a, 1, b, 1, &s, vDSP_Length(a.count)); return s }
var stats: [String: (ok: Int, wrong: Int, unknown: Int, missed: Int, n: Int)] = [:]
var margins: [Float] = []
var scores: [Float] = []
var tDet: [Double] = []
for (name, box) in gt.sorted(by: { $0.key < $1.key }) {
    let src = String(name.split(separator: "_w")[0]) + ".jpg"
    let person = String(name.split(separator: "_")[0])
    let w = name.components(separatedBy: "_w")[1].components(separatedBy: "_")[0]
    let variant = name.hasSuffix("blur.jpg") ? "blur" : "clean"
    let key = variant + " " + (Int(w)! < 40 ? "small(24-32)" : "conv(48-96)")
    let img = load(det + "/frames/" + name)
    let H = img.extent.height, W = img.extent.width
    let (hits, timing) = FaceEngine.scan(img, limit: 8, rank: .attention, minFace: 20)
    tDet.append(timing.detectMs)
    // the face at the ground-truth spot
    let cx = (box[0] + box[2]) / 2 / W, cy = 1 - (box[1] + box[3]) / 2 / H
    var s = stats[key] ?? (0, 0, 0, 0, 0); s.n += 1
    guard let hit = hits.first(where: { $0.usable && $0.box.contains(CGPoint(x: cx, y: cy)) }) else { s.missed += 1; stats[key] = s; continue }
    var best: [String: Float] = [:]
    for g in gallery where g.file != src { best[g.person] = max(best[g.person] ?? -1, dot(g.e, hit.embedding)) }
    let ranked = best.sorted { $0.value > $1.value }
    let top = ranked[0], gap = top.value - ranked[1].value
    if top.value < 0.35 || gap < 0.10 { s.unknown += 1 } else if top.key == person { s.ok += 1 } else { s.wrong += 1 }
    if top.key == person && key.hasSuffix("conv(48-96)") { margins.append(gap); scores.append(top.value) }
    stats[key] = s
}
margins.sort(); scores.sort()
print("conversation-distance: median score", scores[scores.count/2], "median lead over runner-up", margins[margins.count/2], "p10 lead", margins[margins.count/10])
print("detector", FaceEngine.detectorName, "gallery", gallery.count, "median detect ms", tDet.sorted()[tDet.count / 2])
for (k, s) in stats.sorted(by: { $0.key < $1.key }) {
    print(String(format: "  %-20@ named right %3.0f%%  wrong %2d  unsure %3.0f%%  face missed %3.0f%%  (n=%d)", k as NSString,
                 100 * Double(s.ok) / Double(s.n), s.wrong, 100 * Double(s.unknown) / Double(s.n), 100 * Double(s.missed) / Double(s.n), s.n))
}
