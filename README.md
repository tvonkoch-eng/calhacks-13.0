# Cal Hacks 13.0: conversation assistant

First draft: on-device face recognition for the team (Toby, Joaquin, Mirabelle, Avi). Everyone in it has given consent.

- **People**: a minimal CRM of teammates (name, role, facts from `App/people.json`).
- **Add face photos**: on a person, tap the shutter (exactly one face in frame) or import from Photos. 5 to 10 angles each.

- **Glasses (home screen)**: press to identify. Tap Identify on the phone, the Identify button on the lens, or the glasses capture button (needs Inputs enabled for the app in Wearables Developer Center). It matches the newest glasses frame and falls back to a full photo. Wrong match or unknown face: "Save as…" adds that face to a person.

Pipeline: Vision face detection → square crop → Vision feature print → cosine vs. each person's best sample, plus a runner-up margin. No server. Face samples stay on the phone.

## Conversation assist

The phone listens. When someone asks a question about the world — "how tall is the Eiffel Tower" —
the answer appears on the lens. Questions about the people in the room are ignored.

The whole design is about **hiding the latency inside the question instead of after it**. A question
takes one to three seconds to say out loud, and we know roughly what it is well before the last word,
so we start answering mid-sentence:

| | |
|---|---|
| `Listen.swift` | Phone mic → `SFSpeechRecognizer`, on-device, partials every ~100-200 ms. Our own endpointing calls a sentence over after 320 ms of quiet instead of waiting out Apple's ~1.5 s finalize. One recognizer request per utterance. |
| `Question.swift` | ~0 ms gate on every partial: is the tail of this a question we could answer? Strips fillers ("so, um") and lead-ins ("do you know"), drops obviously personal clauses, and refuses to call a clause ready while it's still mid-phrase — "how tall is the" waits, "how tall is the Eiffel" fires. |
| `Assistant.swift` | Fires a **speculative** answer request on the partial transcript, so the model's time-to-first-token overlaps the rest of the sentence. Re-fires if the question grows by 2+ words or the model refused the fragment, capped at 3 tries. A generation counter throws away answers from superseded fires. |
| `Answer.swift` | Local tier (arithmetic, time, date) answers in under a millisecond with no network. Otherwise a streaming call to Groq / Cerebras / OpenAI, one line, ≤12 words. The model returns `SKIP` for anything personal, social, rhetorical or too fragmentary — the real filter, with a regex only as the cheap pre-gate. |
| `Glasses.swift` | A "…" hits the lens the moment a question is detected, then the answer streams in, coalesced to one lens write per 220 ms. It holds for 14 s, then the identity card comes back. |

In the common case the answer is on the lens **before the asker stops talking**. The phone shows how
early, per question, under Transcript.

Known limits: English only, one speaker's question at a time, and no "who said it" — it answers any
question it hears, including your own.

## Running it

```
cp Secrets.example.xcconfig Secrets.xcconfig   # put a Groq key in ANSWER_API_KEY
xcodegen && open CalHacks.xcodeproj            # run on your iPhone
```

Groq or Cerebras is worth it here: their time-to-first-token is ~100-250 ms against ~600 ms+ for the
big hosted models, and first token is what reaches the lens. Without a key, face ID and the local
answer tier still work.
