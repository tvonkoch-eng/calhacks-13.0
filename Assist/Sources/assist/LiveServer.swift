import Foundation
import Network

/// A tiny localhost web server: `/` is the live page, `/events` is a Server-Sent Events stream of
/// everything the pipeline does. New page loads replay the session so far.
final class LiveServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "live-server")
    private var streams: [NWConnection] = []
    private var backlog: [Data] = []
    let port: UInt16

    init(port: UInt16) throws {
        self.port = port
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    /// Send one JSON event to every open page.
    func publish(_ event: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: event) else { return }
        var frame = Data("data: ".utf8)
        frame.append(json)
        frame.append(Data("\n\n".utf8))
        queue.async {
            // Mic level is noise for a late joiner; everything else is replayed.
            if event["type"] as? String != "level" {
                self.backlog.append(frame)
                if self.backlog.count > 5000 { self.backlog.removeFirst(1000) }
            }
            for c in self.streams { c.send(content: frame, completion: .contentProcessed { _ in }) }
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.queue.async { self?.streams.removeAll { $0 === connection } }
            default: break
            }
        }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let head = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            if path.hasPrefix("/events") {
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
                var first = Data(header.utf8)
                for frame in self.backlog { first.append(frame) }
                connection.send(content: first, completion: .contentProcessed { _ in })
                self.streams.append(connection)
            } else {
                let body = Data(livePage.utf8)
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
