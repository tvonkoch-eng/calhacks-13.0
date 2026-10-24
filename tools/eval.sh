#!/bin/sh
# Render, replay and judge every conversation in Tests/conversations/network, then one table.
#   sh tools/eval.sh [out-dir]          (default .build/eval; reuses rendered WAVs)
# Each conversation takes its own length in real time plus ~20 s of judging.
set -e
cd "$(dirname "$0")/.."
out=${1:-.build/eval}
mkdir -p "$out"
for script in Tests/conversations/network/*.txt; do
  name=$(basename "$script" .txt)
  [ "$out/$name.wav" -nt "$script" ] || python3 tools/make-convo.py "$script" "$out/$name.wav" > /dev/null
  sh tools/live-mac.sh --file "$out/$name.wav" --trace "$out/$name.jsonl" < /dev/null > "$out/$name.log" 2>&1
  python3 tools/evaluate.py "$out/$name.wav.json" "$out/$name.jsonl"
done
python3 tools/evaluate.py --summary "$out"/*.eval.json
