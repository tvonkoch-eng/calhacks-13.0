# Conversation aid (branch `muse`): handoff for merging with face detection

A two-person conversation aid for the glasses, built and tested **on the Mac first**. It does four
things: answers what's asked (from wherever the answer lives), defines a term just said that the
wearer wouldn't know, suggests what to say next when the wearer needs it, and knows who they're
talking to. `muse` now sits on top of `main` (0a365c8), so it merges back cleanly.

## How it decides (2026-10-24 redesign)

- **One context everywhere.** Every model call sees the wearer (`WEARER_BACKGROUND`), what's known
  about them (`Aid.met` facts: profile + the CRM's briefing: last conversation, promises both
  ways) and the conversation, including the turn the question is in ("Did you see Figure raised
  again? Do you know how much they raised?").
- **Where the answer lives decides who answers.** The other person's questions stream an answer
  mid-sentence from the conversation, the record or general knowledge; personal or social is
  SKIP; a public fact the model can't give from memory (news, prices, a company's latest) is
  `WEB` and goes to Fetch.ai once the question closes. Place, weather, calendar go to the device
  tools. "Lens, …" from the wearer goes to the tool model with the whole context, so "what did she
  say her company does" and "what did we talk about last time" are answered from memory.
  **Nothing is ever looked up about the people talking**, and what's known about them never goes
  to the web (only the question and the last few lines, to resolve "it").
- **Suggestions: the coach writes what, code decides when.** Only three moments: a lull (3 s of
  quiet after the last word; not right after they asked the wearer something, not after "Lens,
  …"), the wearer asking ("Lens, what should I ask?", a pinch → `aid.suggestNow()`, `s` on the
  Mac), and face ID recognising someone with a record (an opener picking up from last time). The
  call for a moment gets gpt-oss; the per-sentence calls (definitions) go to the qwen backup, so
  the 5/min cap is spent on what the wearer sees. Cleared when said or when the wearer moves on.
- **Removed, because they misfired live:** the coach's own lookups (it researched "Meta AR glasses
  frame rate"), the coach naming people (a name mentioned became THEM's; names now come only from
  "I'm Priya" or face ID), live fact guessing (the CRM recap extracts facts from the whole
  conversation, better), definitions of laws, companies or events (it called the GENIUS Act an AI
  law; those change, so they're lookups), and the interjection rationing it all needed.

Measured on the Mac (typed and replayed conversations): suggestions "What contracts are you
targeting first?", "What skills are you looking for in interns?", opener for a known founder
"How's the CAR T manufacturing scaling going?"; GENIUS Act / Vertex market cap / Figure's raise
looked up in 3.8-7.4 s; "where did you go to school" and "how long have you been coding" stay
quiet; qwen-3.8-27b 23/24 on answer/SKIP/WEB cases (`Tests/answer-latency.py`; it called "who won
the World Series this year" SKIP rather than WEB).

## Models per lane, ranked suggestions, groups (2026-10-24, branch `aid-brain`)

From the research on open conversation copilots (Merge/Convoscope on Mentra, Natively, Omi) and
model/provider benchmarks:

- **Fast models everywhere.** Big models (Sonnet-class) weren't noticeably better on these short
  lines and cost a second or more, so every lane stays on Cerebras. An optional suggest lane
  (`SUGGEST_PROVIDER/API_KEY/MODEL`, unset by default = the coach's model) can move suggestions
  elsewhere. `anthropic` = Claude through the raw Messages API (`Claude` in Coach.swift translates
  the OpenAI-shaped bodies every lane builds, tools included), default `claude-haiku-5-5` with
  thinking off.
- **Ranked suggestions.** The coach returns up to three lines, best first, each scored 1-5. A
  lull shows the best only at 3 or more (a line anyone could say isn't worth breaking a silence);
  asked for or a face just recognised, the best always goes up. The runners-up wait: the next
  lull within 90 s and 5 lines shows one **with no model call**, if it hasn't been said.
- **Groups.** `Aid.nameFor` tags lines with the speaker's first name when face ID knows them, so
  with three people the transcript says who said what instead of THEM twice. People the focus
  leaves stay in every lane's context ("Also in this conversation: …"), and the recognised opener
  fires once per person per conversation, not each time the focus comes back.
- **Exa research** (`RESEARCH_PROVIDER = exa`): search in ~0.4-0.7 s instead of ASI:One's 4-8 s; a
  question that leans on the conversation ("how much did they raise") is first made standalone by
  the backup model, and the condenser cuts the findings to a card as before.
- Measured: the ranked coach on a 3-person lull, qwen-3.8-27b 281 ms, gpt-oss-120b 251 ms, both
  specific ("How do you handle judge drift?"). Claude and Exa are unmeasured here (no keys yet).

### Replay findings and fixes (typed replays of `network/evals.txt` and `catchup.txt`)

| seen | fix |
|---|---|
| Coach rate-limited 55 s on a qwen setup | an empty `COACH_MODEL` took the provider's default (gpt-oss, 5/min); it now takes the answer model |
| "How many people are at this thing?" searched and found a different hackathon | `SITUATION` (event, place, dates) goes into every context; questions about here are resolved to it, or skipped when it's unset |
| Cohen's kappa answered, then defined with the same words | no definition of a term an answer card covered in the last 15 s |
| Research card titled "Cal Hacks 13.0 attendance" | the card's title is the answer ("3,000+ attendees"); the condenser runs on the uncapped answer model, 3.4 → 2.1 s |
| Lull suggestion ignored "we're hiring like crazy" | the newest door THEM opened ranks first ("What's the hardest part of hiring now?") |
| "Did you end up sending that demo video?" asked about the wearer's own promise | the wearer's promises are offered ("Want me to send that demo video?"), only THEM's are asked about |
| Queued runners-up shown in lulls regardless of quality | only ones the coach scored 3+ are kept |

Setup now: everything on `qwen-3.8-27b` on the free Cerebras key (450/min, 150k tokens/min), backup
OpenAI `gpt-4.1-mini` (or `openrouter`, which routes `qwen/qwen3.8-27b` to Cerebras first, once it has
credits), research Exa `instant` (0.4-0.5 s measured).

## On the phone when merging

1. Turn the coach back on: `Assistant.makeAid` has `Tuning aidCoach` default **false** because of
   the misfires above, which are gone by construction. Default it to true.
2. Pinch (or a lens button) → `aid.suggestNow()`.
3. Nothing else: `aid.met(name:label:facts:)` with the CRM briefing already triggers the opener,
   and `LensView.followup` is still the suggestion slot.

## What's here

All shared files are pure Foundation, so the phone and the Mac tool run the same code:

| file | does |
|---|---|
| `App/Listen.swift` | Muse Voice Transcribe realtime ASR in **DIARIZATION** mode: each finished turn comes with a speaker label (A/B) and its loudness at the mic. Runs on iOS and macOS; can replay a WAV. |
| `App/Aid.swift` | The orchestrator: answers (speculative, mid-sentence; only the other person's questions; `WEB` → `lookUp`), the coach (definitions after their sentences; a suggestion at a moment), suggestion timing, tools, the shared context. Plus `Roles` (who's the wearer) and `Talk` (text rules). |
| `App/Lens.swift` | `Compositor`: one passing card (answer > definition) above one pinned suggestion, plus working rows; holds new cards while the wearer talks; drops stale ones. |
| `App/Coach.swift` | The coach prompt (define, suggest), lenient JSON parsing, the `Researcher`s (Fetch.ai ASI:One; OpenAI or Groq web search). |
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
  typing works during a mic session too. `TEST_LOCATION` pins the location. `s` asks for a
  suggestion; `met: Priya · evals founder · Berkeley CS; Last talked Oct 12: raising a seed` acts
  as face ID handing over someone the CRM knows.
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
wearer talks; a suggestion only at a lull, a request or a recognised face, cleared once the wearer
speaks, and never speaks for them; one definition at a time, only for an established term just
said and outside the wearer's field; roles and names come from loudness, self-introductions and
face ID, never from the model (it got roles backwards once, and named THEM after someone
mentioned); nothing is looked up about the people talking.

Known gaps: gpt-oss's Sharpe-ratio answer for market making is textbook-low; the backup model
sometimes defines finance basics; the hold misses the first ~0.5 s of the wearer's turn.

## Merged with face detection (branch `aid-face`)

`face-scrfd` + `muse`. The iOS app runs the aid; steps 1–7 above are done.

- **Who owns the lens** is `App/LensPolicy.swift` (pure, tested in `Tests/LensPolicyTests.swift`):
  1. an Identify press shows its progress and result;
  2. a **fresh identification wins**: the full bio card for `bioHolds` seconds (tuning knob, 6), even over an aid card;
  3. then the aid takes the lens whenever it has something. **both** = a small strip naming the
     person (still in view) above the aid card; **aid** = the aid card alone (nobody known in view);
  4. mic on and the aid quiet: the person shrinks to one line over the Identify row (**compact**),
     or just the Identify row (**idle**);
  5. mic off: the face side exactly as before.
- **Who is THEM**: `Glasses.facing` → `Assistant.facingChanged` → `Aid.met(name:label:facts:)`.
  A recognised name is trusted over a name the coach heard (`Them.recognised`); someone new replaces the profile.
- **`Assist/`** (QM's Mac CLI: Engine/Judge/Transcriber + live page) is left as is. It is not in
  `project.yml`, so it isn't in the app; the app's mic and lens are driven by `Aid` only.
- New Info.plist key `WearerName` (`WEARER_NAME`, defaults to Toby). Build Mac's Secrets.xcconfig
  needs the keys listed under Keys.
- DEBUG preview: `MOCK_GLASSES=1 PREVIEW_PERSON=joaquin PREVIEW_AID='title|detail|follow-up'`
  shows the bio, then the hand-off to "both" after `bioHolds`.
