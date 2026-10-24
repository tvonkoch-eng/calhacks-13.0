# Picking the answer model (measured 2026-10-23)

First token is the only latency that matters here: it is what reaches the lens while the
person is still talking. Everything below was measured from an AWS box against the real
system prompt in `App/Answer.swift`, streaming, `temperature: 0`.

`llama-3.3-70b-versatile`, which this code originally used, has been **retired from Groq** —
it is no longer in `GET /v1/models` and the request 404s.

| model | median TTFT | notes |
|---|---|---|
| **`qwen/qwen3.8-27b`** | **0.10 s** (p90 0.19 s) | no reasoning tokens. 20/20 on answer-vs-SKIP. **In use.** |
| `openai/gpt-oss-120b` | 0.28 s | reasoning model |
| `openai/gpt-oss-20b` | 0.30 s | reasoning model |

Avoid the `gpt-oss` models here. They emit hidden reasoning before any content, so at our
`max_tokens: 48` the budget runs out mid-reasoning and the response comes back with **empty
content** — which `Assistant.swift` cannot distinguish from a deliberate `SKIP`, so the
question is silently dropped and the lens sits on "…". Raising `max_tokens` fixes the
emptiness but not the extra ~200 ms, and 200 ms is most of the lead we are buying with
speculation in the first place.

Accuracy run on `qwen/qwen3.8-27b`, 20 cases, 12 factual + 8 personal/social: 20/20 correct,
answers 1-8 words.

```
how big is the sun                  -> About 1.4 million kilometers in diameter
how tall is the eiffel              -> 330 meters          (mid-sentence fragment)
what year the berlin wall fell      -> 1989
who was the first person to orbit…  -> Yuri Gagarin
how are you doing today             -> SKIP
should we grab lunch                -> SKIP
can you pass me the charger         -> SKIP
```

Re-run with `python3 Tests/groq-latency.py` after exporting `GROQ_KEY`, or whenever Groq
changes its model lineup — which is the failure mode this file exists to catch early.
