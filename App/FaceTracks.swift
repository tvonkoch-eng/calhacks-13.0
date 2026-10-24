import Accelerate
import CoreGraphics
import Foundation

/// Follows each face through the stream and *accumulates* what we know about it.
///
/// The old watch path asked a single frame "is this definitely someone?", demanded two consecutive
/// yeses, and threw the state away on any no. At the measured per-frame pass rate of 11% that is
/// an expected 43 seconds to one auto-identify — of which about 14 ms was computation. Everything
/// else was evidence being discarded.
///
/// Here a face keeps its identity across frames by box overlap, and its embeddings are summed with
/// a decay. The sum of L2-normalised embeddings, renormalised, is the mean direction: averaging two
/// frames measured 99.6% top-1 against 70% for one blurry frame. Noise is uncorrelated between
/// frames and the signal is not, so each extra look is nearly free accuracy.
final class FaceTracker {
    struct Track {
        let id: Int
        /// Normalised box from the most recent frame.
        var box: CGRect
        /// Decayed sum of normalised embeddings; `probe` is this renormalised.
        fileprivate var sum: [Float]
        /// Frames that actually contributed an embedding (blurred looks don't count).
        private(set) var looks: Int
        /// Effective sample count after decay — how much evidence is really in `sum`.
        private(set) var weight: Float
        /// The sharpest look we got, for the avatar and the card.
        var best: FaceHit
        /// Attention from the latest frame: is this the face the wearer is looking at right now.
        var attention: Float
        let firstSeen: Date
        var updated: Date

        /// The fused embedding to match against the gallery.
        var probe: [Float] {
            var v = sum
            var norm: Float = 0
            vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
            norm = sqrt(norm)
            guard norm > 0 else { return v }
            var scale = 1 / norm
            vDSP_vsmul(v, 1, &scale, &v, 1, vDSP_Length(v.count))
            return v
        }
    }

    private(set) var tracks: [Track] = []
    private var nextID = 0

    /// A face that hasn't been seen for this long is a new face next time it appears. At 2 fps one
    /// missed detection is already a 1 s gap, so 1.5 s threw a track away after a single miss.
    var maxAge: TimeInterval = 3
    /// Per-frame weight decay. 0.75 gives an effective window of ~4 frames: long enough to fuse
    /// away blur, short enough that turning your head to a new person doesn't drag the old one in.
    var decay: Float = 0.75
    /// Boxes overlapping by at least this are the same face.
    /// Lowered from 0.25 for 2 fps: a head moves further in the 0.5 s between frames.
    var minOverlap: CGFloat = 0.15

    /// Folds this frame's faces into the tracks and returns the live set, strongest evidence first.
    @discardableResult
    func update(_ hits: [FaceHit], now: Date = Date()) -> [Track] {
        tracks.removeAll { now.timeIntervalSince($0.updated) > maxAge }

        var claimed = Set<Int>()
        // Biggest face first, so when two boxes compete for one track the nearer face wins it.
        for hit in hits.sorted(by: { $0.area > $1.area }) {
            let candidate = tracks.indices
                .filter { !claimed.contains($0) }
                .map { (index: $0, overlap: FaceTracker.overlap(tracks[$0].box, hit.box)) }
                .max { $0.overlap < $1.overlap }

            if let candidate, candidate.overlap >= minOverlap {
                claimed.insert(candidate.index)
                tracks[candidate.index].absorb(hit, decay: decay, now: now)
            } else if hit.usable || hits.count == 1 {
                // A brand-new track needs somewhere to start. A blurred first look still opens one
                // so the next frame has something to attach to, it just carries no evidence.
                claimed.insert(tracks.count)
                tracks.append(Track(id: nextID, box: hit.box,
                                    sum: hit.usable ? hit.embedding.map { $0 * hit.quality } : [],
                                    looks: hit.usable ? 1 : 0,
                                    weight: hit.usable ? hit.quality : 0,
                                    best: hit, attention: hit.attention, firstSeen: now, updated: now))
                nextID += 1
            }
        }
        return tracks.sorted { $0.weight > $1.weight }
    }

    func forget(_ id: Int) { tracks.removeAll { $0.id == id } }
    func reset() { tracks.removeAll() }

    /// Intersection over union of two normalised boxes.
    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let union = a.width * a.height + b.width * b.height - i.width * i.height
        return union > 0 ? (i.width * i.height) / union : 0
    }
}

private extension FaceTracker.Track {
    mutating func absorb(_ hit: FaceHit, decay: Float, now: Date) {
        box = hit.box
        updated = now
        attention = hit.attention
        if hit.sharpness > best.sharpness || !best.usable { best = hit }
        guard hit.usable else { return }
        // Each look counts by its quality: a small or turned face is a weaker vote, so it nudges
        // the fused probe instead of pulling it as hard as a clear frontal look.
        var q = hit.quality
        if sum.count == hit.embedding.count {
            var d = decay
            vDSP_vsmul(sum, 1, &d, &sum, 1, vDSP_Length(sum.count))
            vDSP_vsma(hit.embedding, 1, &q, sum, 1, &sum, 1, vDSP_Length(sum.count))
            weight = weight * decay + q
        } else {
            sum = hit.embedding.map { $0 * q }
            weight = q
        }
        looks += 1
    }
}
