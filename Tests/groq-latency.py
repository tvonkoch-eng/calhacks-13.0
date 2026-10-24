#!/usr/bin/env python3
"""Re-check the answer model: is it still live, how fast is the first token, and does it
still SKIP personal questions? See groq-latency.md.

    GROQ_KEY=gsk_... python3 Tests/groq-latency.py [model ...]
"""
import json, os, statistics, sys, time, urllib.error, urllib.request

KEY = os.environ.get("GROQ_KEY") or sys.exit("set GROQ_KEY")
MODELS = sys.argv[1:] or ["qwen/qwen3.8-27b"]
URL = "https://api.groq.com/openai/v1"
# Older copy of the prompt; the live one is Answerer.prompt in Assist/Sources/AssistCore/Answerer.swift (now also has WAIT and context).
PROMPT = """You help someone wearing smart glasses during a live, in-person conversation. The input is a live speech transcript of a question someone just asked out loud. It may be cut off mid-sentence — infer the obvious full question and answer that.

Answer in ONE line of at most 12 words. No preamble, no restating the question, no punctuation at the end. If the answer is a number or a name, lead with it. Plain facts only.

Reply with exactly SKIP, and nothing else, if the question is personal or social (about the people talking, their feelings, plans, opinions or preferences), rhetorical, a request to do something, or too fragmentary to guess at."""

# (utterance, must_skip). Fragments are the speculative case: we fire mid-sentence.
CASES = [
    ("how big is the sun", False), ("how tall is the eiffel", False),
    ("what year the berlin wall fell", False), ("how many people live in tokyo", False),
    ("what is the capital of peru", False), ("who was the first person to orbit the earth", False),
    ("how far is the moon", False), ("whats the boiling point of water in fahrenheit", False),
    ("who wrote dune", False), ("how fast does light travel", False),
    ("what the gdp of denmark is", False), ("is mount everest still growing", False),
    ("how are you doing today", True), ("did you see the keynote", True),
    ("what do you think of the demo", True), ("should we grab lunch", True),
    ("are you coming to the afterparty", True), ("can you pass me the charger", True),
    ("hows your flight", True), ("what are your plans tonight", True),
]
# A plain Python-urllib UA gets a 403 from Groq's edge; send a real one.
HEAD = {"Authorization": f"Bearer {KEY}", "Content-Type": "application/json",
        "User-Agent": "calhacks-latency/1.0"}


def live(model):
    req = urllib.request.Request(f"{URL}/models", headers=HEAD)
    with urllib.request.urlopen(req, timeout=20) as r:
        return model in {m["id"] for m in json.load(r)["data"]}


def ask(model, question, max_tokens=48):
    """Returns (seconds to first CONTENT token, answer)."""
    body = json.dumps({"model": model, "stream": True, "temperature": 0,
                       "max_tokens": max_tokens,
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
    print(f"\n=== {model} ===")
    if not live(model):
        print("  NOT IN /v1/models — retired. Pick another and update Provider.model.")
        failed = True
        continue
    times, wrong = [], 0
    for question, must_skip in CASES:
        ttft, answer = ask(model, question)
        if ttft is None:
            # Reasoning models burn the budget before emitting content; looks like a SKIP.
            print(f"  EMPTY           | {question!r}")
            wrong += 1
            continue
        times.append(ttft)
        ok = answer.upper().startswith("SKIP") == must_skip
        wrong += not ok
        print(f"  {'ok ' if ok else 'BAD'} ttft {ttft:.2f}s | {question!r} -> {answer[:52]!r}")
    print(f"  {len(CASES) - wrong}/{len(CASES)} correct"
          + (f" | median ttft {statistics.median(times):.2f}s"
             f" p90 {sorted(times)[int(len(times) * 0.9)]:.2f}s" if times else ""))
    failed |= wrong > 0 or (times and statistics.median(times) > 0.35)

sys.exit(1 if failed else 0)
