# Personal CRM (branch `crm`, off `aid-face` 3723b53)

Keeps every conversation as notes: who, a summary, what you learned, what you owe each other,
and the reminders that follow. `App/CRM.swift` (model, pure Foundation), `App/CRMViews.swift`
(phone UI), `Tests/CRMTests.swift` (in `sh Tests/run.sh`).

## The one way in: `CRM.save(_ encounter: Encounter)`

The record of one finished conversation, exactly what the aid hands over:

| field | |
|---|---|
| `name` | what they said their name was |
| `label` | four words: "evals startup founder" |
| `facts` | up to 3 they shared (extra are dropped; repeats of known facts too) |
| `followups` | `Recap.Followup(text:mine:dueInDays:)`. `mine` = the wearer promised (todo), else they did (waiting) |
| `summary` | one line |
| `hook` | the single line worth seeing next time: "asked about hiring" |
| `at`, `ended`, `place` | when, roughly where ("near Union Square, SF") |
| `match` | face-ID person id, if any |

Filed under the match (roster or a saved contact), else the pending contact with the same name
met in the last day, else a new pending contact. Returns the person id.

Until `muse` sends its own record, the CRM builds one itself: `Assistant` feeds it every finished
line and every `Glasses.facing` change; a conversation closes after 120 s of quiet (`crmGap`) or
when the mic goes off, and `Recap` (one model call: coach model, then backup, then answers;
~0.4 s on Cerebras) turns it into an `Encounter`. When muse is merged: call `crm.save` from the aid
at conversation end and delete the `heard`/`tick` feed in `Assistant.listener.onLine`/`disarm`.

## Reading it back

- `lastContext(id)`: "Priya · evals startup founder · asked about hiring". The lens person card
  shows `label · lastLine` under the name (`LensCards.recall`). `lastLine` prefers what you owe
  them, then what they owe you, then the hook.
- `record(id)`: name, label, facts, last summary, open promises both ways; `.briefing` is what
  `Aid.met(facts:)` gets, so the aid starts the next conversation knowing them.
- `keywords(roster:)`: names met in the last day, kept contacts, then the roster. Set as Muse
  keywords on every arm.

## Consent (the model enforces it)

- Recognizable = the roster (opted in) or contacts the wearer tapped **Keep** on. Kept contacts
  join `Store.contacts`, the matcher's candidates, and can get face photos. Pending ones are never
  candidates, get no face photos, get no catch-up reminder, and are deleted after 7 days
  (`pendingDays`) with everything about them.
- No audio, no transcript on disk. The transcript lives in memory until the summary is written
  (or for one retry if it failed). `crm.json` holds only notes; it's written with complete file
  protection.
- Nothing is looked up on anyone: the recap sees only the conversation.

## Default reminders

- Your promise: due tomorrow 9 am unless a time was said; theirs: in 3 days.
- Every conversation with someone kept moves their single "Catch up with X" to 14 days out
  (`checkInDays`).
- Local notifications at the due time (permission asked on the first reminder).

## Not yet done

- `place` is nil from the built-in recorder (no reverse geocoder on this branch; muse has one).
- Not tested in a live conversation on the phone yet.
