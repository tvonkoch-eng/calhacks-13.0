#!/bin/zsh
# Pull Documents/speed.jsonl off the phone and summarize where identify time goes.
# Usage: tools/speed.sh [device-udid]
set -e
DEVICE=${1:-00008150-000E55140204C01C}
OUT=$(mktemp -d)
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier com.tobiasvonkoch.calhacks13 --source Documents/speed.jsonl --destination "$OUT" >/dev/null
FILE=$(find "$OUT" -name "*.jsonl" -o -type f | grep -v "/$" | head -1)
python3 - "$FILE" <<'PY'
import json, statistics, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(f"{len(rows)} identifies\n")
cols = ["source", "path", "resolution", "quality", "bytes", "captureMs", "detectMs", "embedMs", "faces", "toResultMs", "lensMs", "totalMs", "person", "score", "runnerUp"]
print("  ".join(c[:10].rjust(10) for c in cols))
for r in rows[-15:]:
    print("  ".join(str(r.get(c, "")).rjust(10)[:10] for c in cols))
print()
for c in ["captureMs", "fallbackMs", "detectMs", "embedMs", "matchMs", "toResultMs", "lensMs", "totalMs"]:
    v = [r[c] for r in rows if isinstance(r.get(c), (int, float))]
    if v: print(f"{c:>11}  median {statistics.median(v):7.0f}  min {min(v):7.0f}  max {max(v):7.0f}")
PY
