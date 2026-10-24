// swift-tools-version:6.0
// The conversation-assist engine as a Mac command-line tool, for a fast feedback loop:
//   swift run assist mic            live, from the Mac's microphone
//   swift run assist say "…"        speak text with `say`, then run it through the real pipeline
//   swift run assist suite          canned spoken scenarios, pass/fail
//   swift run assist-check          offline logic tests, no audio, no network
// AssistCore and AssistSpeech are compiled straight into the iOS app too (see ../project.yml).
import PackageDescription

let package = Package(
    name: "Assist",
    platforms: [.macOS("26.0")],
    targets: [
        // Pure Foundation: question gate, answer client, speculation engine, event log.
        .target(name: "AssistCore"),
        // Apple's on-device SpeechAnalyzer + audio input (mic or file). Shared with the iPhone app.
        .target(name: "AssistSpeech", dependencies: ["AssistCore"]),
        .executableTarget(
            name: "assist",
            dependencies: ["AssistCore", "AssistSpeech"],
            exclude: ["Info.plist"],
            // A bare CLI needs an embedded Info.plist or macOS kills it on first mic access.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                                           "-Xlinker", "__info_plist", "-Xlinker", "Sources/assist/Info.plist"])]
        ),
        .executableTarget(name: "assist-check", dependencies: ["AssistCore"]),
    ],
    swiftLanguageModes: [.v5]
)
