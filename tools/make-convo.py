#!/usr/bin/env python3
"""Render a two-person script into a WAV the aid can replay, plus ground truth (who said what,
when) for tools/evaluate.py. `say` renders each line to a file; nothing is played aloud.

    python3 tools/make-convo.py Tests/conversations/network/evals.txt /tmp/evals.wav
    sh tools/live-mac.sh --file /tmp/evals.wav

Script lines:
    ME: text           the wearer          THEM: text      the other person
    THEM@-0.4: text    start 0.4 s before the previous line ends (overlap, interruption)
    ME@1.5: text       start 1.5 s after it (instead of the default GAP)
    PAUSE: 4           silence
Header lines (optional, before the first line):
    RATE: 195          words per minute for `say`
    GAP: 0.2           default seconds between lines
    VOICES: ME=Daniel THEM=Samantha
    NOISE: -30         party babble behind everything, in dBFS RMS (omit for none)

THEM is ~9 dB quieter than ME, as the other person stands further from the mic than the
wearer's mouth. Writes target.wav and target.wav.json (the ground truth).
"""
import array, json, math, os, random, re, subprocess, sys, tempfile, wave

RATE_HZ = 24000
GAIN = {"ME": 1.0, "THEM": 0.35}
BABBLE_VOICES = ["Fred", "Tessa", "Rishi", "Tara", "Moira"]
BABBLE_TEXT = [
    "Oh my god, it's been forever, how have you been?", "No, the other one, with the green logo.",
    "I think they're doing drinks after this upstairs.", "Wait, is that the guy from the demo?",
    "We should totally grab coffee next week.", "Honestly the pizza is better than last year.",
    "Did you get a badge at the front or no?", "I'm just here for the stickers, to be fair.",
    "Yeah, they pivoted twice and then it worked.", "Can you hear me? It's so loud in here.",
    "Let me grab your number real quick.", "No way, I went there too, what year?",
]


def render(voice, text, rate, tmp, name):
    aiff, wav = os.path.join(tmp, name + ".aiff"), os.path.join(tmp, name + ".wav")
    subprocess.run(["say", "-v", voice, "-r", str(rate), "-o", aiff, text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE_HZ}", "-c", "1", aiff, wav], check=True)
    with wave.open(wav) as w:
        return [s / 32768 for s in array.array("h", w.readframes(w.getnframes()))]


def mix(track, samples, at, gain):
    start = int(at * RATE_HZ)
    if len(track) < start + len(samples):
        track.extend([0.0] * (start + len(samples) - len(track)))
    for i, s in enumerate(samples):
        track[start + i] += s * gain


def babble(length, level_db, rate, tmp):
    """A few voices chatting at once, looped to `length` samples, at `level_db` RMS."""
    bed = [0.0] * length
    rng = random.Random(7)
    for v, voice in enumerate(BABBLE_VOICES):
        lines = rng.sample(BABBLE_TEXT, len(BABBLE_TEXT))
        talk = render(voice, " ... ".join(lines), rate - 15, tmp, f"babble{v}")
        offset = rng.randrange(len(talk))
        for i in range(length):
            bed[i] += talk[(i + offset) % len(talk)]
    rms = math.sqrt(sum(x * x for x in bed) / len(bed)) or 1
    scale = 10 ** (level_db / 20) / rms
    return [x * scale for x in bed]


def main(script, target):
    rate, gap, noise = 190, 0.2, None
    voice = {"ME": "Daniel", "THEM": "Karen"}
    track, marks = [], []
    end = 0.0
    with tempfile.TemporaryDirectory() as tmp:
        for i, raw in enumerate(open(script).read().strip().splitlines()):
            raw = raw.strip()
            if not raw or raw.startswith("#"):
                continue
            head, _, text = raw.partition(":")
            head, text = head.strip().upper(), text.strip()
            if head == "RATE": rate = int(text); continue
            if head == "GAP": gap = float(text); continue
            if head == "NOISE": noise = float(text); continue
            if head == "VOICES":
                for pair in text.split():
                    who, _, name = pair.partition("=")
                    voice[who.upper()] = name.replace("_", " ")
                continue
            if head == "PAUSE":
                end += float(text or 4)
                continue
            m = re.fullmatch(r"(ME|THEM)(?:@([-+]?\d*\.?\d+))?", head)
            if not m:
                sys.exit(f"bad line: {raw}")
            who, offset = m.group(1), m.group(2)
            start = max(0.0, end + (float(offset) if offset else gap))
            samples = render(voice[who], text, rate, tmp, f"l{i}")
            mix(track, samples, start, GAIN[who])
            stop = start + len(samples) / RATE_HZ
            marks.append({"who": who, "start": round(start, 2), "end": round(stop, 2), "text": text})
            end = max(end, stop)
        track.extend([0.0] * int(RATE_HZ * 1.0))
        if noise is not None:
            bed = babble(len(track), noise, rate, tmp)
            track = [a + b for a, b in zip(track, bed)]
    peak = max(1.0, max(abs(x) for x in track))
    with wave.open(target, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE_HZ)
        w.writeframes(array.array("h", (int(max(-1, min(1, x / peak)) * 32767) for x in track)).tobytes())
    json.dump({"script": script, "voices": voice, "noise_db": noise, "lines": marks}, open(target + ".json", "w"), indent=1)
    print(f"{target}: {len(track) / RATE_HZ:.0f} s, {len(marks)} lines")


main(sys.argv[1], sys.argv[2])
