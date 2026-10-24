#!/usr/bin/env python3
"""Build a noisy, far-field speech benchmark with macOS `say` (pure Python, no numpy).

Each line is spoken by a few voices, then mixed with background chatter (several other voices
talking over each other, like a hackathon floor) at a given SNR, with a little room echo.
Writes clips/<cond>/<voice>-<n>.wav and truth.json.
"""
import json, math, os, random, struct, subprocess, sys, wave, array

LINES = [
    "Who won last year's Cal Hacks?",
    "When did Cal Hacks at Berkeley start?",
    "How far is the Target in the Presidio from the Palace of Fine Arts?",
    "And this is all data that I can use with Groq, with a Q.",
    "How many moons does Jupiter have?",
    "Do you know where the Presidio is?",
    "We might need to speak kind of loudly, which maybe is a product issue.",
    "Who is the president of France?",
    "I mean, we can overlay that onto the Meta Ray-Ban glasses pretty easily.",
    "What year did the Berlin Wall fall?",
    "Joaquin and Mirabelle are working on the face matching part.",
    "Who won the World Cup in twenty twenty two?",
]
CHATTER = [
    "So I was thinking we could grab some food after the opening ceremony if the line is not too long.",
    "Our team is building a robot that sorts recycling using a camera and a little arm.",
    "Did anyone see where they put the extension cords, my laptop is about to die.",
    "The workshop on vector databases starts in ten minutes in the main hall upstairs.",
    "Honestly the wifi here is so slow I am just going to tether to my phone.",
    "We pivoted twice already and it is only nine at night, which is kind of a record.",
]
VOICES = ["Samantha", "Daniel", "Fred", "Eddy (English (US))", "Flo (English (US))"]
BABBLE = ["Albert", "Grandpa (English (US))", "Shelley (English (US))", "Ralph", "Kathy", "Junior"]
SR = 16000

def say(text, voice, path):
    subprocess.run(["say", "-v", voice, "-o", path, "--data-format=LEI16@16000", text], check=True,
                   stderr=subprocess.DEVNULL)

def read(path):
    w = wave.open(path); a = array.array("h", w.readframes(w.getnframes())); w.close()
    return [x / 32768 for x in a]

def write(path, xs):
    peak = max(1e-9, max(abs(x) for x in xs))
    g = min(1.0, 0.95 / peak)
    a = array.array("h", (int(max(-1, min(1, x * g)) * 32767) for x in xs))
    w = wave.open(path, "w"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(a.tobytes()); w.close()

def rms(xs): return math.sqrt(sum(x * x for x in xs) / max(1, len(xs))) or 1e-9

def room(xs, taps=((0.011, 0.35), (0.023, 0.25), (0.041, 0.18), (0.067, 0.1))):
    out = list(xs) + [0.0] * int(0.1 * SR)
    for d, g in taps:
        k = int(d * SR)
        for i, x in enumerate(xs): out[i + k] += g * x
    return out

def main():
    root = os.path.dirname(os.path.abspath(__file__))
    tmp = os.path.join(root, "tmp"); os.makedirs(tmp, exist_ok=True)
    random.seed(7)
    # One long babble track: every chatter line in every babble voice, overlapped.
    tracks = []
    for i, v in enumerate(BABBLE):
        p = os.path.join(tmp, f"bab{i}.wav")
        try: say(" ".join(random.sample(CHATTER, len(CHATTER))), v, p)
        except Exception: continue
        tracks.append(read(p))
    n = max(len(t) for t in tracks)
    babble = [0.0] * n
    for t in tracks:
        off = random.randint(0, SR * 2)
        for i, x in enumerate(t): babble[(i + off) % n] += x
    conds = {"clean": None, "noisy10": 10, "noisy5far": 5}
    truth = {}
    for c in conds: os.makedirs(os.path.join(root, "clips", c), exist_ok=True)
    for vi, v in enumerate(VOICES):
        for li, line in enumerate(LINES):
            if (vi + li) % 2: continue  # half the grid keeps the run short
            p = os.path.join(tmp, "s.wav")
            say(line, v, p)
            s = [0.0] * int(0.3 * SR) + read(p) + [0.0] * int(0.5 * SR)
            name = f"{vi}-{li}.wav"
            truth[name] = line
            for c, snr in conds.items():
                x = s
                if snr is not None:
                    if c.endswith("far"): x = room([y * 0.5 for y in x])
                    start = random.randint(0, n - len(x) - 1)
                    nz = babble[start:start + len(x)]
                    g = rms(x) / rms(nz) / (10 ** (snr / 20))
                    x = [a + g * b for a, b in zip(x, nz)]
                write(os.path.join(root, "clips", c, name), x)
    json.dump(truth, open(os.path.join(root, "truth.json"), "w"), indent=1)
    print(len(truth), "clips x", len(conds), "conditions")

main()
