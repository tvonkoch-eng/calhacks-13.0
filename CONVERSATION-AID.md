# Conversation aid (branch `muse`): handoff for merging with face detection

A two-person conversation aid for the glasses, built and tested **on the Mac only**. It answers
questions asked out loud, defines obscure terms as they're said, and offers a rare, tasteful
line to say next. Branched from `main` at `455cd35`; `main` has moved on since (see Merging).

## What's here

All shared files are pure Foundation, so the phone and the Mac tool run the same code:

| file | does |
|---|---|
| `App/Listen.swift` | Muse Voice Transcribe realtime ASR in **DIARIZATION** mode: each finished turn comes with a speaker label (A/B) and its loudness at the mic. Runs on iOS and macOS; can replay a WAV. |
| `App/Aid.swift` | The orchestrator, three lanes. **Answers**: the speculative mid-sentence answerer, now with conversation context; only the other person's questions. **Coach**: after their sentences/turns, one definition, one rare interjection, who they are. **Research**: a `Researcher` hook (Fetch.ai ASI:One, OpenAI or Groq web search), off by default. Plus `Roles` (who's the wearer) and `Talk` (text rules). |
| `App/Lens.swift` | `Compositor`: one passing card (answer > definition > research) above one pinned interjection; holds new cards while the wearer talks; drops stale ones. |
| `App/Coach.swift` | The coach prompt, lenient JSON parsing, research implementations. |
| `App/Answer.swift` | Providers (cerebras, openai, groq, muse) and the answer prompt. |
| `App/Question.swift` | The local question gate (what's worth answering at all). |
| `tools/live-mac.sh` | The aid on the Mac mic, lens drawn in the terminal. `--file x.wav` replays, `--trace x.jsonl` records. |
| `tools/eval.sh` | Renders `Tests/conversations/network/*.txt` (make-convo.py), replays, and has gpt-5.5 judge every lens item (evaluate.py). |

| `App/Tools.swift` | Tier 2, things only the device knows or can do: `nearby` (Apple Maps search + distance), `weather` (Open-Meteo), `remind` and `next_event` (EventKit). All keyless. gpt-oss picks the tool with native tool calling; the result goes straight onto an answer card with an icon, no second model call. |

`sh Tests/run.sh` runs the offline tests (gate, speculation, lens rules, roles, coach JSON, tools).

## Tools: how they're asked for

- **Commands** start with the wake word: "Lens, how far is the nearest Target?", "Lens, remind me to
  email Maya at 6". Only from the wearer; handled the moment the sentence closes. Actions (reminders)
  only ever come from a command.
- **Questions that need the device** (where, weather, calendar), from either person, go to the
  tools at the end of the sentence, never speculatively ("how far is the nearest" would search
  before "Target" is said). Other questions keep the fast streaming lane.
- A command shows "Finding Target nearby…" if the tool takes over 0.3 s; an overheard question
  only shows the result. Requests run side by side, each on its own card.
- Measured on the Mac (pinned to Union Square, SF): nearest Target 0.76 s, nearest pharmacy
  0.82 s, weather 0.62 s, a plain question through the same path 0.2 s, time 0 s.
- Mac: `sh tools/live-mac.sh --type` takes typed lines ("them: …" for the other person), and
  typing works during a mic session too. `TEST_LOCATION` pins the location.
- **Tier 3, `research`**: one more tool the same model can pick, for the web ("Lens, what's the
  latest on the GENIUS Act?", "a quiet coffee shop near here that's open late"). It gets the
  conversation, what's known about them and a reverse-geocoded "near …", so "her company" and
  "near here" resolve. Engine: Fetch.ai ASI:One (`asi1`) through its **Responses** endpoint with
  the `web_search` tool (the chat endpoint rejects web search). A fast model cuts the answer to a
  card. Measured end to end: 5.4–8 s. This key has no agentic (Agentverse) models.
- iOS needs Info.plist strings: `NSLocationWhenInUseUsageDescription`,
  `NSRemindersFullAccessUsageDescription`, `NSCalendarsFullAccessUsageDescription`. The location
  comes from the phone (the glasses have no GPS).

## Keys (Secrets.xcconfig, never committed)

See `Secrets.example.xcconfig`. The working setup: `MUSE_API_KEY`; answers and coach on
`ANSWER_PROVIDER = cerebras`, `ANSWER_MODEL = gpt-oss-120b`, `ANSWER_PER_MINUTE = 5` (Cerebras free
tier); backup `cerebras` / `qwen-3.8-27b` on the same `CEREBRAS_API_KEY`; research
`RESEARCH_PROVIDER = asi1` with the Fetch key in `RESEARCH_API_KEY`; optional `WEARER_BACKGROUND`;
`OPENAI_API_KEY` only for the eval judge. **The build Mac's Secrets.xcconfig
needs these added**; Toby's copy is in `~/Developer/calhacks-muse/Secrets.xcconfig` on his laptop.

## Merging with main

1. **Expected text conflicts**: `.gitignore`, `App/App.swift`, `project.yml`. Small.
2. **The iOS target does not compile on `muse` yet.** `App/Assistant.swift` still uses the old
   `Listener.onUpdate` and defines `Turn`, which now lives in `Aid.swift`. Rewire it into a thin
   adapter: it owns a `Listener` and an `Aid(config: .fromBundle(wearer:))`;
   `listener.onPartial` → `aid.heard(partial:)`, `listener.onLine` → `aid.heard(line:speaker:level:)`,
   `aid.onLens` → the glasses.
3. **Glasses**: replace `AnswerCard` / `showAnswer` with `LensView` (`aid.lens`). The aid owns the
   lens only while `LensView.isEmpty` is false, which is now brief (cards 8–14 s, an interjection
   up to 20 s), so the face-ID HUD keeps the lens the rest of the time. An identification result
   should win over an aid card while it's fresh.
4. **LensCards**: render `LensView`: header as meta/secondary, card title as heading and detail as
   body/secondary, interjection with the `speechBubble` icon. Lens text is heading/body/meta ×
   primary/secondary only.
5. **project.yml** Info.plist keys, each `$(VAR)`: `MuseAPIKey`, `AnswerProvider`, `AnswerAPIKey`,
   `AnswerModel`, `AnswerPerMinute`, `CoachProvider`, `CoachAPIKey`, `CoachModel`, `BackupProvider`,
   `BackupAPIKey`, `BackupModel`, `ResearchProvider`, `ResearchAPIKey`, `ResearchModel`,
   `WearerBackground`.
6. **`Assist/` on main is a separate conversation assistant** (QM's Engine/Judge/Transcriber + live
   page). Pick one to drive the lens; don't run both on the mic. This branch adds diarized
   who-said-what, the coach, the two-slot lens rules and the judged eval loop.
7. **ConversationView**: show `aid.events` (tag lines with `aid.tag(label)`); a "That was me" tap
   → `aid.markWearer(label)`.

## Behavior that was earned the hard way (don't undo without a reason)

From the judged eval (lens items/min 6–11 → 3.4–4.8, density "about right") and Toby's live runs:
no "…" placeholder card; only the other person's questions get answered; nothing new while the
wearer talks; an interjection is cleared once the wearer speaks and never speaks for them; one
definition at a time, only for a term just said and outside the wearer's field; roles come from
loudness and self-introductions, never from the model (it got it backwards once).

Known gaps: gpt-oss's Sharpe-ratio answer for market making is textbook-low; the backup model
sometimes defines finance basics; the hold misses the first ~0.5 s of the wearer's turn.
