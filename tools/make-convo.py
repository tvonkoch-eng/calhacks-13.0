#!/usr/bin/env python3
"""Turn a two-person script into a WAV the aid can replay, without anyone speaking or anything
being played aloud. `say` renders each line to a file; THEM lines are ~9 dB quieter, as the other
person stands a metre or two further from the mic than the wearer's mouth.

    python3 tools/make-convo.py Tests/conversations/hackathon.txt /tmp/hackathon.wav
    sh tools/live-mac.sh --file /tmp/hackathon.wav

Script lines are `ME: …` or `THEM: …`; a `PAUSE: 6` line inserts that many seconds of silence.
"""
import array, os, subprocess, sys, tempfile, wave

VOICE = {"ME": "Daniel", "THEM": "Karen"}
GAIN = {"ME": 1.0, "THEM": 0.35}
RATE = 24000

script, target = sys.argv[1], sys.argv[2]
out = array.array("h")
with tempfile.TemporaryDirectory() as tmp:
    for i, raw in enumerate(open(script).read().strip().splitlines()):
        who, _, text = raw.partition(":")
        who, text = who.strip().upper(), text.strip()
        if who == "PAUSE":
            out.extend(array.array("h", [0]) * int(RATE * float(text or 6)))
            continue
        aiff, wav = os.path.join(tmp, f"{i}.aiff"), os.path.join(tmp, f"{i}.wav")
        subprocess.run(["say", "-v", VOICE[who], "-o", aiff, text], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", aiff, wav], check=True)
        with wave.open(wav) as w:
            samples = array.array("h", w.readframes(w.getnframes()))
        out.extend(array.array("h", (max(-32768, min(32767, int(s * GAIN[who]))) for s in samples)))
        out.extend(array.array("h", [0]) * int(RATE * 0.7))
with wave.open(target, "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE); w.writeframes(out.tobytes())
print(f"{target}: {len(out) / RATE:.0f} s")
