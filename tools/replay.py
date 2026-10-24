#!/usr/bin/env python3
"""Replay short typed conversations through the live aid (tools/live-mac.sh --type) and print
what it put up after each line: answers, definitions, suggestions, lookups. For comparing
against hand labels, and a clean script against its misheard twin.

    python3 tools/replay.py Tests/conversations/short/founder.txt [more.txt ...]
    python3 tools/replay.py --runs 2 Tests/conversations/short/*.txt     each one twice

Script lines: "THEM: …", "ME: …", "PAUSE: 4" (seconds of silence), "met: Name · role · facts"
(face ID), "SUGGEST" (the wearer asks). Typed lines arrive whole, so a line's speaking time is
capped at 2.5 s: only PAUSE makes a lull.
"""
import json, os, re, subprocess, sys, tempfile, time

ROOT = os.path.join(os.path.dirname(__file__), "..")
SHOWN = {"answer": "answer", "define": "define", "followup": "suggest", "lookup": "lookup", "research": "research"}


def feed(path, pipe):
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
            time.sleep(min(2.5, max(1.2, len(m.group(2).split()) * 0.32)))
    time.sleep(5)
    pipe.write("q\n"); pipe.flush()


def replay(path):
    trace = tempfile.mktemp(suffix=".jsonl")
    proc = subprocess.Popen(["sh", "tools/live-mac.sh", "--type", "--trace", trace], cwd=ROOT,
                            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
    feed(path, proc.stdin)
    proc.wait(timeout=60)
    rows = []
    for line in open(trace):
        event = json.loads(line)
        kind = event.get("kind")
        if kind == "line":
            rows.append(("line", event.get("tag", "?"), event["text"]))
        elif kind in SHOWN and not event["text"].startswith(("used", "passed", "cleared")):
            detail = event.get("detail", "")
            if kind == "define":
                text = f"{event['text']}: {detail}"
            elif kind in ("answer", "research"):
                text = event["text"] + (f"  [{detail.split(' · ')[0]}]" if detail else "")
            else:
                text = event["text"]
            rows.append((SHOWN[kind], "", text))
    os.remove(trace)
    return rows


def main(args):
    runs = 1
    if args[:1] == ["--runs"]:
        runs, args = int(args[1]), args[2:]
    for path in args:
        for run in range(runs):
            print(f"\n## {os.path.basename(path)}" + (f" (run {run + 1})" if runs > 1 else ""))
            for kind, tag, text in replay(path):
                print(f"{tag:5} {text}" if kind == "line" else f"      → {kind}: {text}")


if __name__ == "__main__":
    main(sys.argv[1:])
