#!/bin/sh
# The conversation aid, live on this Mac: the phone app's Listener and Aid with the lens drawn in
# the terminal. Keys come from Secrets.xcconfig, same as the app.
#   sh tools/live-mac.sh                       talk to it (Mac mic)
#   sh tools/live-mac.sh --file convo.wav      replay a recording at real time; never played aloud
#   sh tools/live-mac.sh --trace run.jsonl     also write a timed trace for tools/evaluate.py
#   sh tools/live-mac.sh --type                no audio: type what's said, e.g. "Lens, nearest Target?"
#   sh tools/live-mac.sh 300                   stop after 300 s
# First run: allow microphone access for your terminal app.
set -e
cd "$(dirname "$0")/.."
out=.build/live-mac
mkdir -p "$out"

# One Secrets.xcconfig value, following $(OTHER) references the way Xcode does.
val() {
  v=$(sed -n "s/^$1 *= *//p" Secrets.xcconfig | head -1)
  case "$v" in
    '$('*')') val "$(printf '%s' "$v" | sed 's/^\$(\(.*\))$/\1/')" ;;
    *) printf '%s' "$v" ;;
  esac
}

# Rebuild only when a source or the keys changed.
if [ ! -x "$out/live" ] || [ -n "$(find App tools Secrets.xcconfig -newer "$out/live" -print -quit)" ]; then
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<plist version="1.0"><dict>'
    echo '<key>CFBundleIdentifier</key><string>com.tobiasvonkoch.calhacks13.livemac</string>'
    echo '<key>NSMicrophoneUsageDescription</key><string>Listens to the conversation for the aid.</string>'
    echo '<key>NSLocationUsageDescription</key><string>Finds places near you when you ask.</string>'
    echo '<key>NSLocationWhenInUseUsageDescription</key><string>Finds places near you when you ask.</string>'
    echo '<key>NSRemindersFullAccessUsageDescription</key><string>Sets reminders when you ask.</string>'
    echo '<key>NSCalendarsFullAccessUsageDescription</key><string>Tells you what is next on your calendar.</string>'
    for pair in MuseAPIKey:MUSE_API_KEY AnswerProvider:ANSWER_PROVIDER AnswerAPIKey:ANSWER_API_KEY AnswerModel:ANSWER_MODEL \
                CoachProvider:COACH_PROVIDER CoachAPIKey:COACH_API_KEY CoachModel:COACH_MODEL \
                BackupProvider:BACKUP_PROVIDER BackupAPIKey:BACKUP_API_KEY BackupModel:BACKUP_MODEL \
                ResearchProvider:RESEARCH_PROVIDER ResearchAPIKey:RESEARCH_API_KEY ResearchModel:RESEARCH_MODEL \
                AnswerPerMinute:ANSWER_PER_MINUTE WearerBackground:WEARER_BACKGROUND \
                Tools:TOOLS TestLocation:TEST_LOCATION; do
      printf '<key>%s</key><string>%s</string>\n' "${pair%%:*}" "$(val "${pair#*:}")"
    done
    echo '</dict></plist>'
  } > "$out/Info.plist"
  echo "Building (~30 s)…"
  cp tools/live-mac.swift "$out/main.swift"   # top-level code must live in main.swift
  swiftc -O "$out/main.swift" App/Listen.swift App/Aid.swift App/Lens.swift App/Coach.swift App/Answer.swift App/Question.swift App/Tools.swift \
    -o "$out/live" -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$out/Info.plist" 2>&1 | grep -E "error" && exit 1
fi
"$out/live" "$@"
