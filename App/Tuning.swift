import Foundation

/// Live knobs, changed on a running phone without a build.
///
/// `tools/qm-tune.sh` on the Mac writes `Documents/tuning.json` into the app's data container
/// across the USB cable (`devicectl device copy to`) in about two seconds. Every key in that file
/// is folded into UserDefaults — already where `minScore`, `minGap`, `lensHighlights` and
/// `AutoIdentify` read from — and `Tuning.changed` is posted so anything holding derived state can
/// refresh. `Documents/people.json`, pushed the same way, overrides the bundled roster, so names,
/// roles, ties and highlight copy are editable live too. Reference *photos* still need a build:
/// they are embedded from the bundle at launch.
///
/// Why a polled file and not an HTTP endpoint on the Mac: the cable is already attached for
/// `devicectl`, so this needs no shared Wi-Fi and no venue network that permits client-to-client
/// traffic — the two things most likely to be missing in a demo hall. A 1 Hz `stat` costs nothing.
final class Tuning {
    static let shared = Tuning()
    static let changed = Notification.Name("TuningChanged")

    private static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let tuningURL = docs.appendingPathComponent("tuning.json")
    static let peopleURL = docs.appendingPathComponent("people.json")

    private var stamps: [String: Date] = [:]
    private var timer: Timer?

    /// Reads a stored number as `Float`. UserDefaults keeps every number as an NSNumber, and
    /// `object(forKey:) as? Float` *fails* for one written as a Double unless the value happens to
    /// be exactly representable in 32 bits — 0.72 is not, 0.75 is. That lands as "my push did
    /// nothing" rather than an error, so every numeric read goes through NSNumber instead.
    static func float(_ key: String, _ fallback: Float) -> Float {
        (UserDefaults.standard.object(forKey: key) as? NSNumber)?.floatValue ?? fallback
    }

    static func int(_ key: String, _ fallback: Int) -> Int {
        (UserDefaults.standard.object(forKey: key) as? NSNumber)?.intValue ?? fallback
    }

    static func bool(_ key: String, _ fallback: Bool) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? NSNumber)?.boolValue ?? fallback
    }

    /// Applies whatever is already on disk, then watches both files once a second.
    /// Call before anything reads a threshold.
    func start() {
        applyTuning()
        // Prime the stamps so launch does not fire a change for files that were already there.
        _ = moved(Self.tuningURL)
        _ = moved(Self.peopleURL)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        var changed = false
        if moved(Self.tuningURL) { applyTuning(); changed = true }
        if moved(Self.peopleURL) { changed = true }
        guard changed else { return }
        SpeedLog.record(["event": "tuningPush"])
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// True when the file's modification date moved since the last look (including appearing or
    /// disappearing). A `stat` per file per second — cheaper than any notification API here.
    private func moved(_ url: URL) -> Bool {
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        defer { stamps[url.path] = date }
        return stamps[url.path] != date
    }

    @discardableResult private func applyTuning() -> Bool {
        guard let data = try? Data(contentsOf: Self.tuningURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let defaults = UserDefaults.standard
        for (key, value) in object {
            // JSON null means "forget this key and go back to the built-in default", which is the
            // only way back once a knob has been pushed.
            if value is NSNull { defaults.removeObject(forKey: key) } else { defaults.set(value, forKey: key) }
        }
        return true
    }
}
