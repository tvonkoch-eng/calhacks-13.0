import CoreImage
import Foundation
import Observation
import UIKit

struct Person: Codable, Identifiable, Hashable {
    enum Kind { case school, work, from, interests }

    let id: String
    var name: String
    var role: String
    var school: String?
    var work: String?
    var from: String?
    var interests: String?
    var isMe: Bool?

    /// Background lines in display order.
    var details: [(kind: Kind, text: String)] {
        [(Kind.school, school), (.work, work), (.from, from), (.interests, interests)]
            .compactMap { kind, text in text.map { (kind, $0) } }
    }
}

struct Match {
    let person: Person
    let score: Float
}

/// People come from the bundled people.json; face samples and avatars live in Documents.
@Observable final class Store {
    private(set) var people: [Person] = []
    private(set) var gallery: [String: [[Float]]] = [:]
    private(set) var avatars: [String: UIImage] = [:]
    var threshold: Float = UserDefaults.standard.object(forKey: "threshold") as? Float ?? 0.80 {
        didSet { UserDefaults.standard.set(threshold, forKey: "threshold") }
    }

    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var galleryURL: URL { docs.appendingPathComponent("gallery.json") }
    private func avatarURL(_ id: String) -> URL { docs.appendingPathComponent("avatar-\(id).jpg") }

    init() {
        if let url = Bundle.main.url(forResource: "people", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            people = (try? JSONDecoder().decode([Person].self, from: data)) ?? []
        }
        if let data = try? Data(contentsOf: galleryURL) {
            gallery = (try? JSONDecoder().decode([String: [[Float]]].self, from: data)) ?? [:]
        }
        for person in people {
            if let image = UIImage(contentsOfFile: avatarURL(person.id).path) { avatars[person.id] = image }
            if samples(person.id) == 0 { seed(person.id) }
        }
    }

    /// First-run sample + avatar from a bundled App/Faces/<id>.jpg|png, if there is one.
    private func seed(_ id: String) {
        guard let url = ["jpg", "jpeg", "png"].lazy.compactMap({ Bundle.main.url(forResource: id, withExtension: $0) }).first,
              let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
              let face = FaceEngine.faces(in: image).first else { return }
        enroll(id, face)
    }

    var me: Person? { people.first { $0.isMe == true } }
    var contacts: [Person] { people.filter { $0.isMe != true } }
    func samples(_ id: String) -> Int { gallery[id]?.count ?? 0 }

    func enroll(_ id: String, _ face: FaceHit) {
        gallery[id, default: []].append(face.embedding)
        if avatars[id] == nil {
            let image = UIImage(cgImage: face.crop)
            avatars[id] = image
            try? image.jpegData(compressionQuality: 0.8)?.write(to: avatarURL(id))
        }
        save()
    }

    func reset(_ id: String) {
        gallery[id] = nil
        avatars[id] = nil
        try? FileManager.default.removeItem(at: avatarURL(id))
        save()
    }

    var hasFaces: Bool { gallery.values.contains { !$0.isEmpty } }

    /// Closest person regardless of threshold (for showing why something was "unknown").
    func closest(_ embedding: [Float]) -> Match? { ranked(embedding).first }

    /// Best cosine similarity per person; a match needs to clear the threshold and beat the runner-up.
    func match(_ embedding: [Float]) -> Match? {
        let ranked = ranked(embedding)
        guard let top = ranked.first, top.score >= threshold else { return nil }
        if ranked.count > 1, top.score - ranked[1].score < 0.02 { return nil }
        return top
    }

    private func ranked(_ embedding: [Float]) -> [Match] {
        people.compactMap { person -> Match? in
            guard let samples = gallery[person.id], !samples.isEmpty else { return nil }
            let best = samples.map { zip($0, embedding).reduce(0) { $0 + $1.0 * $1.1 } }.max() ?? 0
            return Match(person: person, score: best)
        }.sorted { $0.score > $1.score }
    }

    private func save() {
        try? JSONEncoder().encode(gallery).write(to: galleryURL)
    }
}
