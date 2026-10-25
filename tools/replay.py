#!/usr/bin/env python3
"""Replay short typed conversations through the live aid (tools/live-mac.sh --type) and print
what it put up after each line: answers, definitions, insights, lookups, each with how long after
the line it landed. For comparing against hand labels, and a clean script against its misheard twin.

    python3 tools/replay.py Tests/conversations/short/founder.txt [more.txt ...]
    python3 tools/replay.py --runs 2 Tests/conversations/short/*.txt     each one twice
    python3 tools/replay.py --stream Tests/conversations/judge.txt       lines arrive word by word

Script lines: "THEM: …", "ME: …", "PAUSE: 4" (seconds of silence), "met: Name · role · facts"
(face ID), "SUGGEST" (the wearer asks).

Without --stream a typed line arrives whole, so its speaking time is capped at 2.5 s and only
PAUSE makes a lull. With --stream it arrives as speech does (AID_STREAM=1: growing partials at
~3.5 words a second), so mid-sentence answers and placeholders run as they would live; that is the
mode to judge timing and flicker by.

Each run ends with: cards shown, how many were placeholders that vanished with nothing on them
(flicker), and the median delay from a line to its first card.
"""
import json, os, re, statistics, subprocess, sys, tempfile, time

ROOT = os.path.join(os.path.dirname(__file__), "..")
SHOWN = {"answer": "answer", "define": "define", "insight": "insight", "followup": "suggest", "lookup": "lookup",
         "research": "research"}
PLACEHOLDERS = ("…", "Looking it up…")


def feed(path, pipe, stream):
    for raw in open(path):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if m := re.match(r"^PAUSE:\s*([\d.]+)", line):
            time.sleep(float(m.group(1)))
        elif line.lower().startswith("met:") or line == "SUGGEST":
            pipe.write(("s" if line == "SUGGEST" else line) + "\n"); pipe.flush()
            time.sleep(1.5)
        elif m := re.match(r"^(ME|THEM):\s*(.*)$", line):
            pipe.write(("them: " if m.group(1) == "THEM" else "") + m.group(2) + "\n"); pipe.flush()
            words = len(m.group(2).split())
            # Streamed: the time it takes to say, plus a turn gap. Whole: capped, so only PAUSE is a lull.
            time.sleep(words * 0.285 + 0.7 if stream else min(2.5, max(1.2, words * 0.32)))
    time.sleep(6)
    pipe.write("q\n"); pipe.flush()


def replay(path, stream):
    trace = tempfile.mktemp(suffix=".jsonl")
    env = dict(os.environ, AID_STREAM="1" if stream else "0")
    proc = subprocess.Popen(["sh", "tools/live-mac.sh", "--type", "--trace", trace], cwd=ROOT, env=env,
                            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
    feed(path, proc.stdin, stream)
    proc.wait(timeout=120)
    events = [json.loads(raw) for raw in open(trace)]
    os.remove(trace)
    lines = [(e.get("t", 0), e.get("tag", "?"), e["text"]) for e in events if e.get("kind") == "line"]
    placeholders, real = set(), set()
    outputs = []   # (line index, delay from that line's end, kind, text)
    for event in events:
        kind, t = event.get("kind"), event.get("t", 0)
        if kind == "lens":
            for card in event.get("cards", []):
                key = (card["kind"], card["id"])
                (placeholders if card["title"] in PLACEHOLDERS else real).add(key)
            continue
        if kind == "status":
            outputs.append((owner(lines, t, ""), None, "status", event["text"]))
            continue
        if kind not in SHOWN or event["text"].startswith(("used", "passed", "cleared")):
            continue
        detail = event.get("detail", "")
        if kind in ("define", "insight"):
            text, about = f"{event['text']}: {detail}", event["text"]
        elif kind in ("answer", "research"):
            asked = detail.split(" \u00b7 ")[0]
            text, about = event["text"] + (f"  [{asked}]" if detail else ""), asked
        else:
            text, about = event["text"] + (f"  ({detail})" if detail else ""), event["text"]
        index = owner(lines, t, about)
        delay = None if index is None else t - lines[index][0]
        outputs.append((index, delay, SHOWN[kind], text))
    delays = [d for _, d, k, _ in outputs if d is not None and k in ("answer", "research", "define", "insight")]
    rows = []
    for i, (_, tag, text) in enumerate(lines):
        rows.append(("line", tag, text, None))
        rows += [(k, "", x, d) for idx, d, k, x in outputs if idx == i]
    rows += [(k, "", x, d) for idx, d, k, x in outputs if idx is None]
    return rows, len(real), len(placeholders - real), delays


def words(text):
    return set(re.sub(r"[^a-z0-9 ]", " ", text.lower()).split()) - {"the", "a", "an", "is", "of", "to", "it", "what", "who", "how"}


def owner(lines, t, about):
    """The line an output belongs to: the one it is about (most shared words) among those that
    ended up to 3 s after it (a mid-sentence answer lands before its line closes) and at most 20 s
    before it; else the last line before it. Its delay is then negative when it beat the line."""
    want = words(about)
    near = [i for i, (lt, _, _) in enumerate(lines) if lt - 3 <= t <= lt + 20 or lt - 3 <= t]
    near = [i for i in near if t - 20 <= lines[i][0] <= t + 3]
    if want and near:
        best = max(near, key=lambda i: (len(want & words(lines[i][2])), lines[i][0]))
        if want & words(lines[best][2]):
            return best
    before = [i for i, (lt, _, _) in enumerate(lines) if lt <= t]
    return before[-1] if before else None


def build():
    """Build the Mac tool before any clock starts: a rebuild (~30 s after a source change) inside
    a replay let the script run ahead, and the last questions never got said."""
    subprocess.run(["sh", "tools/live-mac.sh", "--type"], cwd=ROOT, input="q\n", text=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)


def main(args):
    build()
    runs, stream = 1, False
    while args and args[0].startswith("--"):
        flag = args.pop(0)
        if flag == "--runs":
            runs = int(args.pop(0))
        elif flag == "--stream":
            stream = True
    for path in args:
        for run in range(runs):
            print(f"\n## {os.path.basename(path)}" + (f" (run {run + 1})" if runs > 1 else "") + (" · streamed" if stream else ""))
            rows, shown, flicker, delays = replay(path, stream)
            for kind, tag, text, delay in rows:
                if kind == "line":
                    print(f"{tag:5} {text}")
                else:
                    when = f"{delay:+5.1f}s" if delay is not None else "       "
                    print(f"      {when} {kind}: {text}")
            median = f"{statistics.median(delays):.1f}s" if delays else "—"
            print(f"      = {shown} cards · {flicker} flicker (placeholder, then nothing) · median {median} after the line")


if __name__ == "__main__":
    main(sys.argv[1:])
