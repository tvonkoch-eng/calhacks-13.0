#!/usr/bin/env python3
"""Score one replayed conversation: objective numbers from the ground truth and the aid's trace,
then an independent judge (OpenAI gpt-5.5, a different family from the models under test) on
whether what reached the lens was relevant, timely, correct and worth the glance, and on what
it missed.

    python3 tools/evaluate.py convo.wav.json convo.jsonl     one conversation → convo.eval.json
    python3 tools/evaluate.py --summary out/*.eval.json      one table across runs

Ground truth comes from tools/make-convo.py, the trace from tools/live-mac.sh --trace.
"""
import json, os, re, statistics, sys, urllib.request

ROOT = os.path.join(os.path.dirname(__file__), "..")
JUDGE_MODEL = os.environ.get("JUDGE_MODEL", "gpt-5.5")


def secret(name):
    """A Secrets.xcconfig value, following $(OTHER) references."""
    text = open(os.path.join(ROOT, "Secrets.xcconfig")).read()
    m = re.search(rf"^{name} *= *(.*)$", text, re.M)
    v = m.group(1).strip() if m else ""
    ref = re.fullmatch(r"\$\((\w+)\)", v)
    return secret(ref.group(1)) if ref else v


def words(text):
    return re.sub(r"[^a-z0-9' ]", " ", text.lower()).split()


def wer(ref, hyp):
    """Word error rate of hyp against ref (Levenshtein over words)."""
    d = list(range(len(hyp) + 1))
    for i in range(1, len(ref) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(hyp) + 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (ref[i - 1] != hyp[j - 1]))
    return d[len(hyp)] / max(1, len(ref))


def stamp(t):
    return f"{int(t // 60):02d}:{t % 60:04.1f}"


def lens_items(trace, end):
    """What was on the lens and when: one item per distinct card or interjection."""
    items, card, followup = [], None, None

    def close(item, t):
        if item:
            item["end"] = t
            items.append(item)

    for e in (e for e in trace if e["kind"] == "lens"):
        c, f, t = e.get("card"), e.get("followup"), e["t"]
        # A streaming answer is one item: same card id, growing title.
        key = c and (c["kind"], c.get("id", c["title"]))
        if card and (not c or key != card["key"]):
            close(card, t); card = None
        if c and not card:
            card = {"key": key, "kind": c["kind"], "start": t}
        if card and c:
            card["content"] = f'{c["title"]}' + (f' — {c["detail"]}' if c["detail"] else "")
        if followup and f != followup["content"]:
            close(followup, t); followup = None
        if f and not followup:
            followup = {"kind": "interjection", "content": f, "start": t}
    close(card, end); close(followup, end)
    for item in items:
        item.pop("key", None)
        item["duration"] = round(item["end"] - item["start"], 1)
    return sorted(items, key=lambda i: i["start"])


def speaking(truth, who, t):
    return any(l["who"] == who and l["start"] <= t <= l["end"] for l in truth)


def metrics(truth, trace, items):
    end = max(l["end"] for l in truth)
    heard = [e for e in trace if e["kind"] == "line"]
    # Diarization: each heard line against the ground-truth speaker who finished just before it.
    right = tagged = 0
    for h in heard:
        before = [l for l in truth if l["end"] <= h["t"] + 0.3]
        if not before or h["tag"] not in ("ME", "THEM"):
            continue
        tagged += 1
        right += max(before, key=lambda l: l["end"])["who"] == h["tag"]
    # Latency: from the end of the line that called for an item to the item appearing.
    latencies = []
    for item in items:
        if item["kind"] in ("definition", "answer"):
            probe = item["content"].split(" — ")[0] if item["kind"] == "definition" else item["content"].split(" — ")[-1]
            target = set(w for w in words(probe) if len(w) > 3)
            for l in truth:
                if target and len(target & set(words(l["text"]))) >= max(1, len(target) // 2):
                    latencies.append(round(item["start"] - l["end"], 2))
                    break
    minutes = end / 60
    return {
        "minutes": round(minutes, 2),
        "lines": len(truth),
        "heard_lines": len(heard),
        "wer": round(wer(words(" ".join(l["text"] for l in truth)), words(" ".join(h["text"] for h in heard))), 3),
        "diarization": f"{right}/{tagged}" if tagged else "none tagged",
        "items": len(items),
        "per_minute": round(len(items) / minutes, 1),
        "by_kind": {k: sum(i["kind"] == k for i in items) for k in ("answer", "definition", "research", "interjection")},
        "shown_while_wearer_talks": sum(speaking(truth, "ME", i["start"]) for i in items),
        "latency_s": latencies,
    }


JUDGE = """You evaluate a conversation aid built into AR glasses. The wearer is in a fast, live, \
in-person conversation (a networking event) and glances at a small display. Every glance costs \
attention and eye contact, so an item only helps if the wearer needed it, it arrived while it \
mattered, and it was right. You get what was actually said (ground truth, with times), what the \
aid's speech recognition heard (with speaker tags), and everything the lens showed and when.

Judge strictly from the wearer's point of view, given their background. Score every lens item:
- relevant 0-2: would this wearer need it at all?
- timely 0-2: on screen while it mattered? 0 if the moment had passed, or if it landed while the \
wearer was speaking and pulled their attention.
- correct 0-2: factually right, and right about who said what.
- worth_glance 0-2: net benefit after the cost of looking.
Then list what it missed: an obscure term this wearer likely didn't know, a factual question \
asked out loud that went unanswered, or a moment where one tasteful line would clearly have \
helped. Judge density (too_much, about_right, too_little), distraction 0-10 (10 = constantly \
pulling attention), helpfulness 0-10, the three most valuable concrete changes to the aid's \
behavior, and a two-sentence summary.

Reply with JSON: {"items": [{"at": "mm:ss.s", "kind": "...", "content": "...", "relevant": n, \
"timely": n, "correct": n, "worth_glance": n, "note": "..."}], "missed": [{"at": "mm:ss.s", \
"kind": "definition|answer|interjection", "what": "...", "importance": 1-3}], "density": "...", \
"distraction": n, "helpfulness": n, "fixes": ["...", "...", "..."], "summary": "..."}"""


def judge(truth, trace, items, background):
    said = "\n".join(f'[{stamp(l["start"])}–{stamp(l["end"])}] {l["who"]}: {l["text"]}' for l in truth)
    heard = "\n".join(f'[{stamp(e["t"])}] {e["tag"]}: {e["text"]}' for e in trace if e["kind"] == "line")
    lens = "\n".join(f'[{stamp(i["start"])}–{stamp(i["end"])}] {i["kind"]}: {i["content"]}' for i in items) or "(nothing)"
    other = "\n".join(f'[{stamp(e["t"])}] {e["kind"]}: {e["text"]} {e.get("detail", "")}'.rstrip()
                      for e in trace if e["kind"] in ("lookup", "learned", "roles", "status"))
    user = (f"Wearer: Toby — {background or 'no background given'}.\n\n"
            f"WHAT WAS SAID (ground truth; seconds into the conversation)\n{said}\n\n"
            f"WHAT THE AID HEARD (speech recognition; time = when each turn was finalized)\n{heard}\n\n"
            f"WHAT THE LENS SHOWED (onset–offset)\n{lens}\n\n"
            f"OTHER AID ACTIVITY (not shown on the lens)\n{other or '(none)'}")
    body = {"model": JUDGE_MODEL, "reasoning_effort": "medium", "max_completion_tokens": 6000,
            "response_format": {"type": "json_object"},
            "messages": [{"role": "system", "content": JUDGE}, {"role": "user", "content": user}]}
    req = urllib.request.Request("https://api.openai.com/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {secret('OPENAI_API_KEY')}",
                                          "Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.loads(json.load(r)["choices"][0]["message"]["content"])


def score(verdict):
    items = verdict.get("items", [])
    if not items:
        return None
    return round(sum(i.get("relevant", 0) + i.get("timely", 0) + i.get("correct", 0) + i.get("worth_glance", 0)
                     for i in items) / (8 * len(items)) * 100)


def report(name, m, verdict):
    print(f"\n=== {name} ===")
    print(f"  {m['minutes']} min · {m['lines']} lines (heard {m['heard_lines']}) · WER {m['wer']:.0%} · "
          f"speaker tags right {m['diarization']}")
    print(f"  lens: {m['items']} items, {m['per_minute']}/min {m['by_kind']} · "
          f"{m['shown_while_wearer_talks']} while the wearer talked · latency {m['latency_s']} s")
    for i in verdict.get("items", []):
        pts = i.get("relevant", 0) + i.get("timely", 0) + i.get("correct", 0) + i.get("worth_glance", 0)
        print(f"  {pts}/8 [{i.get('at')}] {i.get('kind')}: {i.get('content')}  — {i.get('note', '')}")
    for x in verdict.get("missed", []):
        print(f"  MISSED ({x.get('importance')}) [{x.get('at')}] {x.get('kind')}: {x.get('what')}")
    print(f"  judge: density {verdict.get('density')} · distraction {verdict.get('distraction')}/10 · "
          f"helpfulness {verdict.get('helpfulness')}/10 · item score {score(verdict)}%")
    for f in verdict.get("fixes", []):
        print(f"  fix: {f}")
    print(f"  {verdict.get('summary', '')}")


def summary(paths):
    rows = [json.load(open(p)) for p in paths]
    print(f"\n{'conversation':<12} {'items':>5} {'/min':>5} {'talk':>5} {'WER':>5} {'tags':>6} "
          f"{'score':>6} {'help':>5} {'distr':>6} {'missed':>6}  density")
    for r in rows:
        m, v = r["metrics"], r["verdict"]
        print(f"{r['name']:<12} {m['items']:>5} {m['per_minute']:>5} {m['shown_while_wearer_talks']:>5} "
              f"{m['wer']:>5.0%} {m['diarization']:>6} {str(score(v)) + '%':>6} {v.get('helpfulness'):>5} "
              f"{v.get('distraction'):>6} {len(v.get('missed', [])):>6}  {v.get('density')}")


def main():
    if sys.argv[1] == "--summary":
        return summary(sys.argv[2:])
    truth_path, trace_path = sys.argv[1], sys.argv[2]
    truth = json.load(open(truth_path))["lines"]
    trace = [json.loads(l) for l in open(trace_path) if l.strip()]
    end = max(l["end"] for l in truth) + 3
    items = lens_items(trace, end)
    m = metrics(truth, trace, items)
    verdict = judge(truth, trace, items, secret("WEARER_BACKGROUND"))
    name = os.path.basename(trace_path).rsplit(".", 1)[0]
    report(name, m, verdict)
    json.dump({"name": name, "metrics": m, "items": items, "verdict": verdict},
              open(trace_path.rsplit(".", 1)[0] + ".eval.json", "w"), indent=1)


main()
