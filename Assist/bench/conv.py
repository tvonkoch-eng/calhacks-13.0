#!/usr/bin/env python3
"""One noisy two-person conversation: alternating voices, pauses, hackathon chatter at SNR dB."""
import sys, os, random, math, wave, array, subprocess
sys.argv += [] 
SR = 16000
LINES = [("Samantha", "Hey, so how was your flight?"), ("Daniel", "Pretty good. We're using Groq for the answers, it's super fast."),
 ("Samantha", "Who won last year's Cal Hacks?"), ("Daniel", "No idea, honestly."),
 ("Samantha", "How many moons does Jupiter have?"), ("Daniel", "It was like 30 degrees in Lisbon when we went."),
 ("Samantha", "How far is the Presidio from the Palace of Fine Arts?"), ("Daniel", "We might need to speak kind of loudly, which maybe is a product issue."),
 ("Samantha", "When did Cal Hacks at Berkeley start?"), ("Daniel", "Should we grab dinner after the judging?"),
 ("Samantha", "What year did the Berlin Wall fall?")]
def say(t, v, p): subprocess.run(["say", "-v", v, "-o", p, "--data-format=LEI16@16000", t], check=True)
def read(p):
    w = wave.open(p); a = array.array("h", w.readframes(w.getnframes())); w.close(); return [x / 32768 for x in a]
def rms(x): return math.sqrt(sum(y*y for y in x) / max(1, len(x))) or 1e-9
snr = float(sys.argv[1]) if len(sys.argv) > 1 else 8
os.makedirs("tmp", exist_ok=True)
speech = []
for v, t in LINES:
    say(t, v, "tmp/c.wav"); speech += [0.0] * int(0.9 * SR) + read("tmp/c.wav")
speech += [0.0] * SR
bab = [0.0] * len(speech)
for i in range(6):
    p = f"tmp/bab{i}.wav"
    if not os.path.exists(p): continue
    b = read(p); off = random.randint(0, len(b))
    for j in range(len(bab)): bab[j] += b[(j + off) % len(b)]
g = rms([x for x in speech if x]) / rms(bab) / (10 ** (snr / 20))
mix = [a + g * b for a, b in zip(speech, bab)]
pk = max(abs(x) for x in mix)
w = wave.open("conversation.wav", "w"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
w.writeframes(array.array("h", (int(x / pk * 0.9 * 32767) for x in mix)).tobytes()); w.close()
print("conversation.wav", round(len(mix) / SR, 1), "s at", snr, "dB")
