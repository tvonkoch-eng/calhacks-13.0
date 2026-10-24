import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Groq's free tier caps each model at a number of requests per day (1,000 for the chat models,
/// 2,000 for Whisper). Every response says how many are left; this keeps the latest per model so
/// the UI can show it and callers can switch models before a cap bites.
public final class Quota: @unchecked Sendable {
    public static let shared = Quota()
    public struct Entry: Sendable { public let remaining: Int; public let limit: Int }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public func note(_ response: URLResponse?, model: String) {
        guard let http = response as? HTTPURLResponse,
              let r = http.value(forHTTPHeaderField: "x-ratelimit-remaining-requests").flatMap(Int.init),
              let l = http.value(forHTTPHeaderField: "x-ratelimit-limit-requests").flatMap(Int.init) else { return }
        lock.lock(); entries[model] = Entry(remaining: r, limit: l); lock.unlock()
    }

    public var snapshot: [String: Entry] { lock.lock(); defer { lock.unlock() }; return entries }

    /// "answers 483/1000 · whisper 1921/2000 · …" (requests left today).
    public var summary: String {
        snapshot.sorted { $0.key < $1.key }.map { "\(Self.label($0.key)) \($0.value.remaining)/\($0.value.limit)" }
            .joined(separator: " · ")
    }

    static func label(_ model: String) -> String {
        switch model {
        case Provider.groq.model: "answers"
        case "openai/gpt-oss-120b": "grader"
        case "openai/gpt-oss-20b": "side notes"
        case let m where m.hasPrefix("whisper"): "whisper"
        default: model
        }
    }
}
