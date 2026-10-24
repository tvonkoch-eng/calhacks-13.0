import Foundation
import os

/// One JSON line per identify in Documents/speed.jsonl (and the device log, category "speed").
/// Pull it with: xcrun devicectl device copy from ... --source Documents/speed.jsonl
enum SpeedLog {
    private static let logger = Logger(subsystem: "com.tobiasvonkoch.calhacks13", category: "speed")
    private static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("speed.jsonl")

    static func record(_ fields: [String: Any]) {
        var fields = fields
        fields["at"] = ISO8601DateFormatter().string(from: .now)
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        logger.info("\(line, privacy: .public)")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((line + "\n").utf8).write(to: url)
        }
    }
}

/// Milliseconds since `start`, rounded to 0.1.
func ms(since start: CFAbsoluteTime) -> Double {
    ((CFAbsoluteTimeGetCurrent() - start) * 10_000).rounded() / 10
}
