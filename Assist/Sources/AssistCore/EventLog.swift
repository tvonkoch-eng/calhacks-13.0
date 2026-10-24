import Foundation

/// One line per thing that happened, stamped with seconds since listening started.
/// Printed for humans and appended as JSON lines for tools (and for pasting back to an agent).
public final class EventLog: @unchecked Sendable {
    public enum Kind: String, Sendable {
        case hear, final, gate, fire, token, answer, personal, incomplete, commit, carry, abandon,
             lens, judge, error, info
    }

    public var now: @Sendable () -> Double
    /// Print every partial hypothesis, not just the decisions.
    public var verbose: Bool
    public var echo: Bool
    /// Sees every event (live UI). Called on whatever thread logged it.
    public var observer: (@Sendable (_ t: Double, _ kind: Kind, _ message: String) -> Void)?
    private let file: FileHandle?
    private let lock = NSLock()
    private let color = isatty(fileno(stdout)) != 0

    public init(path: URL? = nil, verbose: Bool = false, echo: Bool = true,
                now: @escaping @Sendable () -> Double) {
        self.now = now
        self.verbose = verbose
        self.echo = echo
        if let path {
            try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path.path, contents: nil)
            file = try? FileHandle(forWritingTo: path)
        } else {
            file = nil
        }
    }

    public func callAsFunction(_ kind: Kind, _ message: String, _ fields: [String: String] = [:]) {
        let t = now()
        observer?(t, kind, message)
        lock.lock()
        defer { lock.unlock() }
        if let file {
            var record: [String: String] = fields
            record["t"] = String(format: "%.3f", t)
            record["kind"] = kind.rawValue
            record["msg"] = message
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                file.write(data)
                file.write(Data("\n".utf8))
            }
        }
        guard echo, verbose || kind != .hear else { return }
        let stamp = String(format: "%7.3f", t)
        let tag = kind.rawValue.uppercased().padding(toLength: 10, withPad: " ", startingAt: 0)
        print("\(paint(stamp, "2"))  \(paint(tag, style(kind)))\(message)")
        fflush(stdout)
    }

    private func style(_ kind: Kind) -> String {
        switch kind {
        case .hear: "2"
        case .final: "1"
        case .fire: "33;1"
        case .token, .answer: "32;1"
        case .lens: "36;1"
        case .judge: "34;1"
        case .personal, .incomplete, .abandon: "35"
        case .error: "31;1"
        default: "0"
        }
    }

    private func paint(_ s: String, _ code: String) -> String {
        color ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }
}

/// Seconds since listening started. Set `zero` the instant the first audio is fed, so engine time
/// and the recognizer's audio timestamps share one clock.
public final class SessionClock: @unchecked Sendable {
    public var zero = Date()
    public init() {}
    public func now() -> Double { Date().timeIntervalSince(zero) }
}
