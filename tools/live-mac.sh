#!/bin/sh
# The conversation aid, live on this Mac: the phone app's Listener and Aid with the lens drawn in
# the terminal. Keys come from Secrets.xcconfig, same as the app.
#   sh tools/live-mac.sh                       talk to it (Mac mic)
#   sh tools/live-mac.sh --file convo.wav      replay a recording at real time; never played aloud
#   sh tools/live-mac.sh 300                   stop after 300 s
# First run: allow microphone access for your terminal app.
set -e
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# One Secrets.xcconfig value, following $(OTHER) references the way Xcode does.
val() {
  v=$(sed -n "s/^$1 *= *//p" Secrets.xcconfig | head -1)
  case "$v" in
    '$('*')') val "$(printf '%s' "$v" | sed 's/^\$(\(.*\))$/\1/')" ;;
    *) printf '%s' "$v" ;;
  esac
}

cat > "$out/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.tobiasvonkoch.calhacks13.livemac</string>
<key>NSMicrophoneUsageDescription</key><string>Listens to the conversation for the aid.</string>
EOF
for pair in MuseAPIKey:MUSE_API_KEY AnswerProvider:ANSWER_PROVIDER AnswerAPIKey:ANSWER_API_KEY AnswerModel:ANSWER_MODEL \
            CoachProvider:COACH_PROVIDER CoachAPIKey:COACH_API_KEY CoachModel:COACH_MODEL \
            BackupProvider:BACKUP_PROVIDER BackupAPIKey:BACKUP_API_KEY BackupModel:BACKUP_MODEL \
            ResearchProvider:RESEARCH_PROVIDER ResearchAPIKey:RESEARCH_API_KEY ResearchModel:RESEARCH_MODEL \
            WearerBackground:WEARER_BACKGROUND; do
  printf '<key>%s</key><string>%s</string>\n' "${pair%%:*}" "$(val "${pair#*:}")" >> "$out/Info.plist"
done
echo '</dict></plist>' >> "$out/Info.plist"

echo "Building (~30 s)…"
cp tools/live-mac.swift "$out/main.swift"   # top-level code must live in main.swift
swiftc -O "$out/main.swift" App/Listen.swift App/Aid.swift App/Lens.swift App/Coach.swift App/Answer.swift App/Question.swift \
  -o "$out/live" -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$out/Info.plist" 2>&1 | grep -E "error" && exit 1
"$out/live" "$@"
