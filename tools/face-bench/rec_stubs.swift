import Foundation
enum Tuning {
    static func float(_ k: String, _ f: Float) -> Float { (ProcessInfo.processInfo.environment[k]).flatMap(Float.init) ?? f }
    static func bool(_ k: String, _ f: Bool) -> Bool { (ProcessInfo.processInfo.environment[k]).map { $0 == "1" } ?? f }
}
enum SpeedLog { static func record(_ f: [String: Any]) { FileHandle.standardError.write("log \(f)\n".data(using: .utf8)!) } }
