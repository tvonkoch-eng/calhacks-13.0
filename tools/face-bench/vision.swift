import Foundation
import Vision
import CoreImage
let dir = CommandLine.arguments[1]
let files = try! FileManager.default.contentsOfDirectory(atPath: dir + "/frames").filter { $0.hasSuffix(".jpg") }.sorted()
var out: [String: [[Double]]] = [:]; var times: [Double] = []
for f in files {
    let img = CIImage(contentsOf: URL(fileURLWithPath: dir + "/frames/" + f))!
    let W = img.extent.width, H = img.extent.height
    let req = VNDetectFaceLandmarksRequest()
    let t0 = CFAbsoluteTimeGetCurrent()
    try? VNImageRequestHandler(ciImage: img).perform([req])
    times.append(CFAbsoluteTimeGetCurrent() - t0)
    out[f] = (req.results ?? []).map { o in
        let b = o.boundingBox
        return [b.minX * W, (1 - b.maxY) * H, b.maxX * W, (1 - b.minY) * H]
    }
}
times.sort()
print("vision median ms", (times[times.count / 2] * 10000).rounded() / 10)
try! JSONSerialization.data(withJSONObject: ["vision": out]).write(to: URL(fileURLWithPath: dir + "/vision_results.json"))
