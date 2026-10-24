import Foundation

/// Streams pipeline events to a remote collector ($ASSIST_SHARE), so someone else can watch a live
/// session and debug it. Batched every 300 ms; best effort, never blocks the pipeline.
final class Forwarder: @unchecked Sendable {
    private let url: URL
    private let session: String
    private let queue = DispatchQueue(label: "forwarder")
    private var pending: [[String: Any]] = []
    private var timer: DispatchSourceTimer?
    private var inFlight = false

    init(url: URL, session: String) {
        self.url = url
        self.session = session
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.3, repeating: 0.3)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        self.timer = timer
    }

    func send(_ event: [String: Any]) {
        let type = event["type"] as? String
        if type == "level" || type == "transcript" || type == "turns" { return }
        var e = event
        e["wall"] = Date().timeIntervalSince1970
        queue.async { self.pending.append(e) }
    }

    /// Push whatever is left, synchronously (end of run).
    func drain() {
        for _ in 0..<30 {
            let empty = queue.sync { pending.isEmpty && !inFlight }
            if empty { return }
            queue.sync { flush() }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func flush() {
        guard !inFlight, !pending.isEmpty else { return }
        let batch = pending
        pending = []
        guard let body = try? JSONSerialization.data(withJSONObject: ["session": session, "events": batch]) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        inFlight = true
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            self.queue.async {
                self.inFlight = false
                let ok = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
                if !ok { self.pending.insert(contentsOf: batch.suffix(500), at: 0) }
            }
        }.resume()
    }
}
