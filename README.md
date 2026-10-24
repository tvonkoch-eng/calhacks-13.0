# Cal Hacks 13.0: conversation assistant

First draft: on-device face recognition for the team (Toby, Joaquin, Mirabelle, Avi). Everyone in it has given consent.

- **People**: a minimal CRM of teammates (name, role, facts from `App/people.json`).
- **Add face photos**: on a person, tap the shutter (exactly one face in frame) or import from Photos. 5 to 10 angles each.
- **Seed photos**: drop `App/Faces/<id>.jpg` (`joaquin`, `mirabelle`, `avi`, `toby`). On first launch each one becomes that person's avatar and first face sample.
- **Glasses (home screen)**: press to identify. Tap Identify on the phone, the Identify button on the lens, or the glasses capture button (needs Inputs enabled for the app in Wearables Developer Center). It matches the newest glasses frame and falls back to a full photo. Wrong match or unknown face: "Save as…" adds that face to a person.

Pipeline: Vision face detection → square crop → Vision feature print → cosine vs. each person's best sample, plus a runner-up margin. No server. Face samples stay on the phone.

## Conversation assist

The phone (or the Mac) listens. When someone asks a question about the world, like "how tall is the
Eiffel Tower", the answer appears on the lens. Questions about the people in the room are ignored.

The latency has to land **inside the question, not after it**. A question takes one to three seconds
to say and is usually recognisable before the last word, so the answer request fires on the partial
transcript and the model's ~100 ms to first token overlaps the end of the sentence.

All the logic is a Swift package in `Assist/`, shared by the iPhone app and a Mac command-line tool:

| | |
|---|---|
| `AssistSpeech/Transcriber.swift` | Apple's on-device **SpeechAnalyzer** (iOS/macOS 26): word-by-word hypotheses, closes sentences itself with `?`, no session limit. Mic or a recording replayed in real time. |
| `AssistCore/QuestionGate.swift` | ~0 ms check on every hypothesis: strips fillers and lead-ins, drops obviously personal questions and statements, ignores half-spoken words ("the E"), won't fire mid-phrase ("how tall is the"). |
| `AssistCore/Engine.swift` | Fires early, refires when the question grows 2+ words / adds a number / the model said WAIT. A sentence the recognizer closes mid-phrase ("Do you know what?") is **carried** into the next one, so a pause never splits a question. Sends the last few sentences as context ("how far is *it*"). |
| `AssistCore/Answerer.swift` | Local tier (math, time, date, no network). Otherwise streams Groq `qwen/qwen3.8-27b`. Model replies SKIP (personal) or WAIT (too cut off); neither is ever shown. |
| `AssistCore/EventLog.swift` | Every decision, timestamped, to the console and to `Assist/logs/*.jsonl`. |

### The Mac loop (start here)

Needs macOS 26 and Swift 6.2+ (Xcode or just the Command Line Tools).

```
cd Assist
swift run assist mic                 # talk to it; Ctrl-C prints a summary table
swift run assist say "So how tall is the [[slnc 700]] Eiffel Tower?"   # spoken by `say`, real pipeline
swift run assist suite               # 11 spoken scenarios, pass/fail, timings
swift run assist file clip.m4a       # replay a recording of a failure, in real time
swift run assist-check               # offline logic tests, no audio or network
```

Add `-v` to see every partial hypothesis. The first mic run asks for Microphone permission for your
terminal app.

Measured on a Mac mini (M-series, macOS 26.3), `assist suite`: **11/11**. Model first token 80-170 ms.
"lead" is how long the answer was up before the speaker stopped talking: +0.9 s on the Eiffel Tower
(fired on "how tall is the Eiff"), around -0.1 to -0.9 s on short questions, where the remaining delay
is the recognizer holding back the last word. Turning off its `fastResults` mode costs another ~1 s.

### On the phone

`project.yml` compiles `Assist/Sources/AssistCore` and `AssistSpeech` into the app (iOS 26 target);
`App/Assistant.swift` is a thin wrapper, and `Glasses` is the `AnswerDisplay`.

```
xcodegen && open CalHacks.xcodeproj   # run on your iPhone
```

Known limits: English only; no speaker separation (it answers any factual question it hears,
including the wearer's).
