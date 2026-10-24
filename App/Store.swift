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

    /// How you know them. The highest-value line on the lens after the name, because it is not a
    /// fact about them -- it is a fact about the two of you.
    var tie: String?
    /// Ranked once, when the person is written, by recency x specificity x is-it-theirs: a thing
    /// they built last month outranks a title they have held a year. The lens takes the first few.
    var highlights: [String]?
    /// The personal half -- committees, sports, languages. Secondary, but not the first thing cut:
    /// someone's sport says more about who you are about to talk to than a third internship does.
    var personal: String?
    /// Where this came from and how old it is. On every card, because the first thing anyone asks
    /// glasses that knew their name is "how did you know that?".
    var source: String?

    /// What the lens leads with under the name: what they do now, not where they studied.
    var headline: String { work ?? school ?? role }

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

    /// Bump whenever the embedding space changes (crop rule, de-rolling, model). Samples saved in
    /// an older space are not comparable with new ones, and mixing them flattens every score —
    /// which is exactly the failure this guards against.
    private static let galleryVersion = 2
    private static let versionKey = "galleryVersion"

    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var galleryURL: URL { docs.appendingPathComponent("gallery.json") }
    private var seenURL: URL { docs.appendingPathComponent("seen.json") }
    private var encountersURL: URL { docs.appendingPathComponent("encounters.json") }
    private var notesURL: URL { docs.appendingPathComponent("notes.json") }
    private func avatarURL(_ id: String) -> URL { docs.appendingPathComponent("avatar-\(id).jpg") }

    init() {
        loadPeople()
        if UserDefaults.standard.integer(forKey: Self.versionKey) != Self.galleryVersion {
            // Existing embeddings came from crops that were never straightened. Drop them and let
            // the bundled references reload, rather than compare across two different spaces.
            try? FileManager.default.removeItem(at: galleryURL)
            for person in people { UserDefaults.standard.removeObject(forKey: "refsLoaded.\(person.id)") }
            UserDefaults.standard.set(Self.galleryVersion, forKey: Self.versionKey)
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
        hydrate()
        NotificationCenter.default.addObserver(forName: Tuning.changed, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    /// The roster. A pushed `Documents/people.json` wins over the bundled copy, so names, roles,
    /// ties and highlight copy can be corrected on a running phone — see `Tuning`.
    private func loadPeople() {
        let pushed = try? Data(contentsOf: Tuning.peopleURL)
        let bundled = Bundle.main.url(forResource: "people", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        // A pushed file that will not decode must not empty the roster mid-demo: fall back.
        for data in [pushed, bundled].compactMap(\.self) {
            if let decoded = try? JSONDecoder().decode([Person].self, from: data), !decoded.isEmpty {
                people = decoded
                return
            }
        }
    }

    /// Avatar and face samples for everyone currently on the roster. Both steps remember what
    /// they have already done, so running this again after a roster push only touches new people.
    private func hydrate() {
        for person in people {
            if let image = UIImage(contentsOfFile: avatarURL(person.id).path) { avatars[person.id] = image }
            if avatars[person.id] == nil { seedAvatar(person.id) }
            loadReferences(person.id)
        }
    }

    /// Re-reads the roster after a push. Embeddings stay: the expensive part is the face work, and
    /// editing somebody's job title does not invalidate what their face looks like.
    func reload() {
        let before = people
        loadPeople()
        guard people != before else { return }
        hydrate()
    }

    /// Every bundled reference photo for one person, in filename order.
    ///
    /// Xcode flattens bundled files, so `App/References/<id>_NN.<ext>` arrives as `<id>_NN.<ext>`
    /// at the top of the bundle. This used to look for `jpg` alone, so a photo added straight off
    /// a phone or out of a screenshot — `.jpeg`, `.png`, `.heic` — rode all the way from the repo
    /// into the app bundle and was then silently never embedded. The failure looked exactly like
    /// "I added photos and nothing happened".
    private static let referenceExtensions = ["jpg", "JPG", "jpeg", "JPEG", "png", "PNG", "heic", "HEIC"]

    private func referenceURLs(_ id: String) -> [URL] {
        var seen = Set<String>()
        return Self.referenceExtensions
            .flatMap { Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }
            .filter { $0.lastPathComponent.hasPrefix("\(id)_") && seen.insert($0.lastPathComponent).inserted }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Bundled App/References/<id>_NN.jpg are match examples. We remember the exact filenames that
    /// have been embedded, not just "done": the old one-shot Bool meant photos added to an existing
    /// install were silently ignored forever, which is the failure you hit the moment you try to
    /// improve someone's recognition by giving them more pictures.
    private func loadReferences(_ id: String) {
        let key = "refsLoaded.\(id)"
        let defaults = UserDefaults.standard
        let urls = referenceURLs(id)
        guard !urls.isEmpty else { return }

        var loaded: Set<String>
        if let names = defaults.stringArray(forKey: key) {
            loaded = Set(names)
        } else {
            // Upgrading from the Bool flag: it does not say which files it covered, so re-embed the
            // whole set once rather than leave this person with a half-loaded gallery.
            if defaults.bool(forKey: key) { gallery[id] = nil }
            loaded = []
        }

        let fresh = urls.filter { !loaded.contains($0.lastPathComponent) }
        guard !fresh.isEmpty else { return }
        for url in fresh {
            guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
                  let face = FaceEngine.faces(in: image).first else { continue }
            gallery[id, default: []].append(face.embedding)
        }
        save()
        // Record every bundled name, including any Vision could not read, so a photo that will
        // never yield a face is not re-decoded on every single launch.
        defaults.set(urls.map(\.lastPathComponent), forKey: key)
    }

    /// Headshot from a bundled App/Faces/<id>.jpg|png becomes the avatar only; match examples come from the photo library.
    private func seedAvatar(_ id: String) {
        // Prefer a dedicated headshot, but fall back to the first bundled reference photo: someone
        // who has References/<id>_NN.jpg but no Faces/<id> image would otherwise get a nameplate
        // with no face on it.
        let headshot = ["jpg", "jpeg", "png"].lazy.compactMap { Bundle.main.url(forResource: id, withExtension: $0) }.first
        let firstReference = referenceURLs(id).first
        guard let url = headshot ?? firstReference,
              let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return }
        // Face crop when Vision finds one, otherwise the headshot as is.
        guard let avatar = FaceEngine.faces(in: image).first.map({ UIImage(cgImage: $0.crop) })
                ?? UIImage(contentsOfFile: url.path) else { return }
        avatars[id] = avatar
        try? avatar.jpegData(compressionQuality: 0.8)?.write(to: avatarURL(id))
    }

    /// Everyone in the roster is a candidate. There used to be a wearer flag on Person whose
    /// holder was kept out of matching, but both phones ship the same people.json, so the flag
    /// made whoever it named unrecognizable on every device at once. Per-device identity, if we
    /// want it later, belongs in UserDefaults — not in a file identical for the whole team.
    var contacts: [Person] { people }

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

    /// A name has to be earned: close enough outright, and clear of the runner-up.
    ///
    /// Re-measured on the bundled references in the de-rolled space (the earlier 0.62/0.02 numbers
    /// came from a three-photo sample and do not hold): same person scores 0.570 at worst and
    /// 0.802 typically, different people reach 0.794 at worst and 0.589 typically. The absolute
    /// score alone cannot separate those tails — the margin over the runner-up does the real work,
    /// and it is ~0.26 for a true match versus ~0.00 for a coin flip.
    ///
    /// Both are overridable from UserDefaults so they can be tuned on the phone without a rebuild.
    var minScore: Float { Tuning.float("minScore", 0.72) }
    var minGap: Float { Tuning.float("minGap", 0.05) }

    /// A deliberate press still means "tell me who that is", but nearest-neighbour on its own will
    /// always name somebody: it was naming people at 0.45 with the runner-up 0.006 behind, which is
    /// a coin toss presented as a fact. Below the bar we say "not sure" instead.
    func match(_ embedding: [Float]) -> Match? { best(embedding, score: minScore, gap: minGap) }

    /// Unprompted recognition has no thumb behind it, so it is held to a stricter bar than a press.
    func confidentMatch(_ embedding: [Float]) -> Match? {
        best(embedding, score: minScore + 0.03, gap: minGap * 2)
    }

    private func best(_ embedding: [Float], score: Float, gap: Float) -> Match? {
        let ranked = ranked(embedding)
        guard let top = ranked.first, top.score >= score else { return nil }
        if let runnerUp = ranked.dropFirst().first, top.score - runnerUp.score < gap { return nil }
        return top
    }

    /// Every enrolled person is a candidate.
    func ranked(_ embedding: [Float]) -> [Match] {
        contacts.compactMap { person -> Match? in
            guard let samples = gallery[person.id], !samples.isEmpty else { return nil }
            let best = samples.map { zip($0, embedding).reduce(0) { $0 + $1.0 * $1.1 } }.max() ?? 0
            return Match(person: person, score: best)
        }.sorted { $0.score > $1.score }
    }

    private func save() {
        try? JSONEncoder().encode(gallery).write(to: galleryURL)
    }
}
