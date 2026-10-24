# Short replays: what the aid puts up (2026-10-24)

`python3 tools/replay.py --runs 3 Tests/conversations/short/*.txt` (qwen-3.8-27b on Cerebras for
every lane, Exa research, `SITUATION` = Cal Hacks 13.0). Each script has a `.misheard` twin with
recognizer-style errors; three runs each. "→ after" is the line the item fired after.

## founder (Priya, evals startup)

| after | clean (3 runs) | misheard (3 runs) |
|---|---|---|
| "…recalibrate with Cohen's kappa" | define **Cohen's kappa**: statistic measuring agreement between raters (3/3) | same (3/3), heard "co ends kappa" |
| "…LLM as a judge" (heard "LOM") | nothing | define **LLM as a judge**: using AI to evaluate AI outputs (3/3) |
| lull after "hiring two eval engineers" (heard "evil") | suggest "What does the eval engineer role look like?" / "What does an eval engineer do day to day?" | suggest "What do the eval engineers do day-to-day?" / "…do there?" |

## catchup (Dana, known from face ID; Toby owes her a video)

| after | clean | misheard |
|---|---|---|
| face recognised | suggest "Did you make it to Lisbon?" (2/3), "Want me to send you the demo video?" (1/3) | "Did you make it to Lisbon?" (3/3) |
| "what time the closing ceremony starts tomorrow" | lookup "What time does the closing ceremony start at Cal Hacks 13.0 tomorrow?" → nothing found, no card (3/3) | same (3/3), heard without "?" |
| lull after "Not sure actually" | "How was the flight back?", "Did you get to see the sights?", nothing | "Want me to send that demo video?" (2/3), "What did you build for the hackathon?" |

## quant (ex-Jane Street, now robotics)

| after | clean | misheard |
|---|---|---|
| "a lot of gamma scalping" | nothing (in the wearer's field) | nothing |
| "what was the S&P close yesterday" (heard "s and p clothes") | answer **7,623.68**, "S&P 500 closed down 0.52% on October 23, 2026" (3/3) | **7,623.68** (2/3), "-0.52%" (1/3) |
| lull after "warehouse picking arms" (heard "where house") | "What's the hardest part of picking arms?" (3/3) | same (2/3), "What does the picking arm do?" |

## Fixed on the way here (each seen in an earlier replay)

- "LOM" defined as "Large Outcome Model": unknown acronyms are now read as misheard familiar ones, never expanded.
- Suggestions repeating misheard words ("the evil engineer role"): everything is written in the intended words.
- "We just raised a seed around" turned into a web lookup that made up "$2.2M": a rebuilt request now needs a question from them.
- "Did you catch the demo video?" asked about the wearer's own promise: checked in code, so the next-best line is used.
- "Not yet announced" cards: research that doesn't answer shows nothing.
- A queued older line ("What base models do you test?") beat the fresh hiring opening: queued lines only show if they haven't said anything new since.
- "Gamma scalping" defined for a finance student: hedging the Greeks is in the field.

## Known differences

- The misheard founder script defines "LLM as a judge" and the clean one doesn't: the misheard term
  makes the model think it's worth explaining. Mild, but it's the one place mishearing adds a card.
- The closing ceremony time isn't found on the web: the card stays off rather than guessing.
