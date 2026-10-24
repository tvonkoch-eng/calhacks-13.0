#!/bin/sh
# Live side-by-side test on this Mac's microphone, no phone or glasses needed.
#   sh tools/live-mac.sh [seconds]     (default 600; Ctrl-C any time for the summary)
# Keys come from Secrets.xcconfig: MUSE_API_KEY (required), GROQ_API_KEY, DEEPGRAM_API_KEY,
# MOSS_PROJECT_ID + MOSS_PROJECT_KEY — each missing one just turns its lane off.
# First run: allow microphone (and speech recognition, for the APPLE lane) for your terminal app.
set -e
cd "$(dirname "$0")/.."
out=$(mktemp -d)
val() { sed -n "s/^$1 *= *//p" Secrets.xcconfig | head -1; }
cleanup() { [ -n "$moss" ] && kill "$moss" 2>/dev/null; rm -rf "$out"; }
trap cleanup EXIT INT TERM

cat > "$out/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.tobiasvonkoch.calhacks13.livemac</string>
<key>MuseAPIKey</key><string>$(val MUSE_API_KEY)</string>
<key>GroqAPIKey</key><string>$(val GROQ_API_KEY)</string>
<key>DeepgramAPIKey</key><string>$(val DEEPGRAM_API_KEY)</string>
<key>NSMicrophoneUsageDescription</key><string>Live test of the question pipeline.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Compares Apple's on-device recognizer.</string>
</dict></plist>
EOF
{ echo 'import AVFoundation'; echo 'import Foundation'
  sed -n '/^private final class Uplink/,$p' App/Listen.swift | sed 's/^private final class Uplink/final class Uplink/'; } > "$out/Uplink.swift"
cp tools/live-mac.swift "$out/main.swift"
echo "Building the live tool (~30 s)…"
swiftc -O "$out/main.swift" "$out/Uplink.swift" App/Question.swift App/Answer.swift -o "$out/live" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$out/Info.plist" 2>&1 | grep -E "error" && exit 1

if curl -s -o /dev/null "http://127.0.0.1:8765/q?text=hi"; then
  echo "Moss already running on :8765, reusing it."
elif [ -n "$(val MOSS_PROJECT_ID)" ]; then
  if [ ! -x .venv-moss/bin/python ]; then
    echo "First run: installing Moss into .venv-moss …"
    py=$(command -v python3.13 || command -v python3.12 || command -v python3.11 || command -v python3)
    "$py" -m venv .venv-moss && .venv-moss/bin/pip -q install moss
  fi
  echo "Starting Moss…"
  MOSS_PROJECT_ID=$(val MOSS_PROJECT_ID) MOSS_PROJECT_KEY=$(val MOSS_PROJECT_KEY) \
    .venv-moss/bin/python tools/moss-sidecar.py App/people.json &
  moss=$!
  for _ in $(seq 1 60); do curl -s -o /dev/null "http://127.0.0.1:8765/q?text=hi" && break; sleep 0.5; done
fi
"$out/live" "${1:-600}"
