#!/usr/bin/env python3
"""Answer model check, any provider: is it live, how fast is the first visible word, does it SKIP
personal questions, and does it say WEB instead of guessing at recent ones? Reads the prompt
straight out of App/Answer.swift, so it can't drift.

    PROVIDER=cerebras KEY=csk-... python3 Tests/answer-latency.py gpt-oss-120b qwen-3.8-27b
    PROVIDER=openai   KEY=sk-...  python3 Tests/answer-latency.py gpt-4.1-mini
    PACE=12.5 …       seconds between requests, for low rate limits (Cerebras gpt-oss: 5/min)
"""
import json, os, re, statistics, sys, time, urllib.error, urllib.request

PROVIDERS = {
    "cerebras": "https://api.cerebras.ai/v1",
    "openai": "https://api.openai.com/v1",
    "groq": "https://api.groq.com/openai/v1",
    "muse": "https://api.meta.ai/v1",
}
PROVIDER = os.environ.get("PROVIDER", "cerebras")
URL = PROVIDERS[PROVIDER]
KEY = os.environ.get("KEY") or sys.exit("set KEY")
MODELS = sys.argv[1:] or sys.exit("name at least one model")
PACE = float(os.environ.get("PACE", "0"))


def swift_prompt():
    """Answerer.prompt from App/Answer.swift: a Swift multi-line literal with \\ line joins."""
    source = open(os.path.join(os.path.dirname(__file__), "..", "App", "Answer.swift")).read()
    body = re.search(r'private static let prompt = """\n(.*?)\n    """', source, re.S).group(1)
    text = ""
    for line in body.split("\n"):
        line = line[4:] if line.startswith("    ") else line
        text += line[:-1] if line.endswith("\\") else line + "\n"
    return text.strip()


PROMPT = swift_prompt()

# (utterance, expected): "answer" (from memory; WEB is allowed but counted), "skip" (personal or
# social), "web" (recent or niche public facts: must not be guessed). Fragments are the speculative
# case: we fire mid-sentence.
CASES = [
    ("how big is the sun", "answer"), ("how tall is the eiffel", "answer"),
    ("what year the berlin wall fell", "answer"), ("how many people live in tokyo", "answer"),
    ("what is the capital of peru", "answer"), ("who was the first person to orbit the earth", "answer"),
    ("how far is the moon", "answer"), ("whats the boiling point of water in fahrenheit", "answer"),
    ("who wrote dune", "answer"), ("how fast does light travel", "answer"),
    ("what the gdp of denmark is", "answer"), ("is mount everest still growing", "answer"),
    ("how are you doing today", "skip"), ("did you see the keynote", "skip"),
    ("what do you think of the demo", "skip"), ("should we grab lunch", "skip"),
    ("are you coming to the afterparty", "skip"), ("can you pass me the charger", "skip"),
    ("hows your flight", "skip"), ("what are your plans tonight", "skip"),
    ("what the latest is on the genius act", "web"), ("whats nvidias stock price right now", "web"),
    ("who won the world series this year", "web"), ("when is the next spacex launch", "web"),
]
HEAD = {"Authorization": f"Bearer {KEY}", "Content-Type": "application/json", "User-Agent": "calhacks-latency/1.0"}


def extras(model):
    """Same rule as Provider.extras(model:) in App/Answer.swift."""
    if "gpt-oss" in model:
        return {"max_tokens": 600, "reasoning_effort": "low"}
    if PROVIDER == "cerebras" and "qwen" in model:
        return {"max_tokens": 48, "reasoning_effort": "none"}
    if PROVIDER == "muse":
        return {"max_tokens": 400, "reasoning_effort": "minimal"}
    return {"max_tokens": 48}


def ask(model, question):
    """Returns (seconds to first CONTENT token, answer)."""
    body = json.dumps({"model": model, "stream": True, "temperature": 0, **extras(model),
                       "messages": [{"role": "system", "content": PROMPT},
                                    {"role": "user", "content": question}]}).encode()
    req = urllib.request.Request(f"{URL}/chat/completions", data=body, headers=HEAD, method="POST")
    start, ttft, answer = time.time(), None, ""
    with urllib.request.urlopen(req, timeout=30) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data: "):
                continue
            payload = line[6:]
            if payload == "[DONE]":
                break
            delta = (json.loads(payload).get("choices") or [{}])[0].get("delta") or {}
            if chunk := delta.get("content"):
                ttft = ttft if ttft is not None else time.time() - start
                answer += chunk
    return ttft, answer.strip()


failed = False
for model in MODELS:
    print(f"\n=== {PROVIDER} {model} ===")
    times, wrong, looked = [], 0, 0
    for i, (question, expected) in enumerate(CASES):
        if PACE and i:
            time.sleep(PACE)
        try:
            ttft, answer = ask(model, question)
        except urllib.error.HTTPError as e:
            print(f"  HTTP {e.code}        | {question!r} {e.read().decode()[:120]}")
            wrong += 1
            continue
        if ttft is None:
            print(f"  EMPTY           | {question!r}")   # reasoning ate the budget; looks like a SKIP
            wrong += 1
            continue
        times.append(ttft)
        said = answer.upper().strip(" .")
        got = "skip" if said.startswith("SKIP") else "web" if said == "WEB" else "answer"
        ok = got == expected or (expected == "answer" and got == "web")
        looked += got == "web" and expected == "answer"
        wrong += not ok
        print(f"  {'ok ' if ok else 'BAD'} ttft {ttft:.2f}s | {question!r} -> {answer[:52]!r}")
    print(f"  {len(CASES) - wrong}/{len(CASES)} correct, {looked} plain facts sent to the web"
          + (f" | median ttft {statistics.median(times):.2f}s"
             f" p90 {sorted(times)[int(len(times) * 0.9)]:.2f}s" if times else ""))
    failed |= wrong > 0

sys.exit(1 if failed else 0)
