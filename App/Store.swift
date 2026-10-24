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
    /// Short labels for chips: school, company, city.
    var tags: [String]?
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
    private(set) var lastSeen: [String: Date] = [:]
    /// Every time each person was recognized, oldest first.
    private(set) var encounters: [String: [Date]] = [:]
    private(set) var notes: [String: String] = [:]
    /// Small copies of avatars for the lens; every lens update ships the image over Bluetooth.
    @ObservationIgnored private var lensAvatars: [String: UIImage] = [:]

    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var galleryURL: URL { docs.appendingPathComponent("gallery.json") }
    private var seenURL: URL { docs.appendingPathComponent("seen.json") }
    private var encountersURL: URL { docs.appendingPathComponent("encounters.json") }
    private var notesURL: URL { docs.appendingPathComponent("notes.json") }
    private func avatarURL(_ id: String) -> URL { docs.appendingPathComponent("avatar-\(id).jpg") }

    init() {
        if let url = Bundle.main.url(forResource: "people", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            people = (try? JSONDecoder().decode([Person].self, from: data)) ?? []
        }
        if let data = try? Data(contentsOf: galleryURL) {
            gallery = (try? JSONDecoder().decode([String: [[Float]]].self, from: data)) ?? [:]
        }
        if let data = try? Data(contentsOf: seenURL) {
            lastSeen = (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
        }
        if let data = try? Data(contentsOf: encountersURL) {
            encounters = (try? JSONDecoder().decode([String: [Date]].self, from: data)) ?? [:]
        }
        if let data = try? Data(contentsOf: notesURL) {
            notes = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        // Installs from before the encounter log: their last sighting is their first encounter.
        for (id, date) in lastSeen where encounters[id] == nil { encounters[id] = [date] }
        for person in people {
            if let image = UIImage(contentsOfFile: avatarURL(person.id).path) { avatars[person.id] = image }
            if avatars[person.id] == nil { seedAvatar(person.id) }
            loadReferences(person.id)
        }
    }

    /// Bundled App/References/<id>/*.jpg are match examples, loaded once per person (flag in UserDefaults).
    private func loadReferences(_ id: String) {
        let key = "refsLoaded.\(id)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        // Xcode flattens bundled files, so references are named <id>_NN.jpg.
        let urls = (Bundle.main.urls(forResourcesWithExtension: "jpg", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("\(id)_") }
        guard !urls.isEmpty else { return }
        for url in urls {
            guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
                  let face = FaceEngine.faces(in: image).first else { continue }
            gallery[id, default: []].append(face.embedding)
        }
        save()
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Headshot from a bundled App/Faces/<id>.jpg|png becomes the avatar only; match examples come from the photo library.
    private func seedAvatar(_ id: String) {
        guard let url = ["jpg", "jpeg", "png"].lazy.compactMap({ Bundle.main.url(forResource: id, withExtension: $0) }).first,
              let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return }
        // Face crop when Vision finds one, otherwise the headshot as is.
        guard let avatar = FaceEngine.faces(in: image).first.map({ UIImage(cgImage: $0.crop) })
                ?? UIImage(contentsOfFile: url.path) else { return }
        avatars[id] = avatar
        try? avatar.jpegData(compressionQuality: 0.8)?.write(to: avatarURL(id))
    }

    var me: Person? { people.first { $0.isMe == true } }
    var contacts: [Person] { people.filter { $0.isMe != true } }

    /// Contacts, most recently seen first; people you haven't met keep their file order.
    var recents: [Person] {
        contacts.enumerated().sorted { a, b in
            let da = lastSeen[a.element.id] ?? .distantPast, db = lastSeen[b.element.id] ?? .distantPast
            return da != db ? da > db : a.offset < b.offset
        }.map(\.element)
    }

    /// Records a conversation now; returns the previous time so a wrong match can be undone.
    /// Moving forward logs an encounter (sightings within 5 minutes are the same conversation);
    /// moving back, as when a wrong match is corrected, drops the encounters after `date`.
    @discardableResult func markSeen(_ id: String, at date: Date? = .now) -> Date? {
        let previous = lastSeen[id]
        lastSeen[id] = date
        var log = encounters[id] ?? []
        if let date, date >= (previous ?? .distantPast) {
            if let last = log.last, date.timeIntervalSince(last) < 5 * 60 { log[log.count - 1] = date } else { log.append(date) }
        } else {
            log.removeAll { $0 > (date ?? .distantPast) }
        }
        encounters[id] = log.isEmpty ? nil : log
        try? JSONEncoder().encode(lastSeen).write(to: seenURL)
        try? JSONEncoder().encode(encounters).write(to: encountersURL)
        return previous
    }

    func setNote(_ id: String, _ text: String) {
        notes[id] = text.isEmpty ? nil : text
        try? JSONEncoder().encode(notes).write(to: notesURL)
    }

    /// People you've met at least once, for the counter on the lens.
    var connectedCount: Int { contacts.filter { encounters[$0.id]?.isEmpty == false }.count }

    /// Met today, for the summary line.
    var metToday: Int { lastSeen.values.filter { Calendar.current.isDateInToday($0) }.count }
    func samples(_ id: String) -> Int { gallery[id]?.count ?? 0 }

    func lensAvatar(_ id: String) -> UIImage? {
        if let cached = lensAvatars[id] { return cached }
        guard let avatar = avatars[id] else { return nil }
        let size = CGSize(width: 96, height: 96)
        let small = UIGraphicsImageRenderer(size: size).image { _ in avatar.draw(in: CGRect(origin: .zero, size: size)) }
        lensAvatars[id] = small
        return small
    }

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
        lensAvatars[id] = nil
        gallery[id] = nil
        avatars[id] = nil
        try? FileManager.default.removeItem(at: avatarURL(id))
        save()
    }

    var hasFaces: Bool { gallery.values.contains { !$0.isEmpty } }

    /// The team is tiny and everyone is known, so the closest person always wins.
    func match(_ embedding: [Float]) -> Match? { ranked(embedding).first }

    func ranked(_ embedding: [Float]) -> [Match] {
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
