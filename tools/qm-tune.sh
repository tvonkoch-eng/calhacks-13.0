#!/bin/bash
# qm-tune.sh — change a running phone's knobs, and the roster text, WITHOUT a build.
#
#   DEV=toby bash ~/calhacks/qm-tune.sh minGap=0.03 minScore=0.70
#   DEV=toby bash ~/calhacks/qm-tune.sh AutoIdentify=false lensHighlights=2
#   DEV=toby bash ~/calhacks/qm-tune.sh people          # push App/people.json as it stands
#   DEV=toby bash ~/calhacks/qm-tune.sh minGap=         # forget the override, back to built-in
#   DEV=toby bash ~/calhacks/qm-tune.sh --show          # what this phone is currently carrying
#   DEV="toby joaquin" ...                              # several phones, in parallel
#
# The app stats Documents/tuning.json once a second (App/Tuning.swift) and folds every key into
# UserDefaults, so the change takes hold in about a second with the app still running and the
# glasses still paired. No xcodebuild, no keychain, no relaunch, no build lock.
#
# Values are typed from how they look: true/false -> bool, 0.72 -> number, anything else -> string,
# empty -> remove the key. Overrides accumulate across calls (state in .state/tuning-<id>.json).
#
# No bash arrays anywhere in here: macOS still ships bash 3.2, where an empty array under `set -u`
# is an unbound variable and the script dies on the "no pairs given" path.
set -u
set -o pipefail

CAL=~/calhacks
TREE=$CAL/calhacks-13.0
STATE=$CAL/.state
BUNDLE=com.jdelpego.calhacks13
mkdir -p "$STATE"

JOAQUIN=19CCB825-541A-5CC8-994B-AD337F81050D
JOAQUIN14=B598F2F8-7B4F-596D-AFDE-7360EAFD25E9
TOBY=9671B519-AC01-5E01-B9BF-99D999EAE82B
devname() { case "$1" in
  $JOAQUIN) echo "Joaquin's iPhone 17 Pro";; $JOAQUIN14) echo "Joaquin's iPhone 14 Pro";;
  $TOBY) echo "Toby's iPhone 17 Pro";; *) echo "$1";; esac; }

if [ -z "${DEV:-}" ]; then
  echo "REFUSED: DEV is required — name the phone explicitly."
  echo "  DEV=joaquin | joaquin14 | toby   (or a raw devicectl id; space-separated for several)"
  exit 2
fi
DEVS=""
for d in $DEV; do
  case "$d" in
    joaquin|joaquin17) id=$JOAQUIN;; joaquin14) id=$JOAQUIN14;; toby) id=$TOBY;; *) id=$d;;
  esac
  DEVS="$DEVS $id"
done
DEVS=$(echo $DEVS | tr ' ' '\n' | awk '!seen[$0]++' | tr '\n' ' ')

CONNECTED=$(xcrun devicectl list devices 2>/dev/null)
for id in $DEVS; do
  if ! echo "$CONNECTED" | grep "$id" | grep -q "connected"; then
    echo "REFUSED: $(devname $id) ($id) is not connected — plug it in and unlock it."
    echo "$CONNECTED"; exit 2
  fi
done

PUSH_PEOPLE=0
SHOW=0
NPAIRS=0
PAIRFILE=$(mktemp /tmp/qm-tune-pairs.XXXXXX)
trap 'rm -f "$PAIRFILE"' EXIT
for a in "$@"; do
  case "$a" in
    people|--people) PUSH_PEOPLE=1;;
    --show|-s) SHOW=1;;
    *=*) printf '%s\n' "$a" >> "$PAIRFILE"; NPAIRS=$((NPAIRS+1));;
    *) echo "unrecognised argument: $a (want key=value, 'people', or '--show')"; exit 2;;
  esac
done
if [ "$SHOW" = "0" ] && [ "$NPAIRS" = "0" ] && [ "$PUSH_PEOPLE" = "0" ]; then
  echo "nothing to do — pass key=value pairs, 'people', or '--show'"; exit 2
fi

copy_to() { # $1=device  $2=local file  $3=name under Documents/
  xcrun devicectl device copy to --device "$1" --quiet \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "$2" --destination "Documents/$3"
}

for id in $DEVS; do
 (
  FILE=$STATE/tuning-$id.json
  [ -f "$FILE" ] || echo '{}' > "$FILE"

  if [ "$SHOW" = "1" ]; then
    echo "== $(devname $id)"
    sed 's/^/  /' "$FILE"
    exit 0
  fi

  if [ "$NPAIRS" != "0" ]; then
    # The pairs go in by PATH, not on stdin: `python3 -` already reads its program from stdin,
    # so a heredoc'd script and piped data cannot share it — the data silently comes back empty.
    python3 - "$FILE" "$PAIRFILE" <<'PY' || exit 1
import json, sys
path, pairfile = sys.argv[1], sys.argv[2]
try:
    state = json.load(open(path))
except Exception:
    state = {}
for line in open(pairfile).read().splitlines():
    if not line.strip():
        continue
    key, _, raw = line.partition("=")
    if raw == "":
        state[key] = None          # the app treats null as "forget this key"
        continue
    low = raw.lower()
    if low in ("true", "false"):
        state[key] = (low == "true")
    else:
        try:
            state[key] = int(raw) if raw.lstrip("-").isdigit() else float(raw)
        except ValueError:
            state[key] = raw
json.dump(state, open(path, "w"), sort_keys=True)
print("  " + json.dumps(state, sort_keys=True))
PY
    copy_to "$id" "$FILE" tuning.json || { echo "TUNE_FAILED  $(devname $id)"; exit 1; }
    echo "TUNE_OK  $(devname $id)  (live within ~1s)"
  fi

  if [ "$PUSH_PEOPLE" = "1" ]; then
    copy_to "$id" "$TREE/App/people.json" people.json || { echo "PEOPLE_FAILED  $(devname $id)"; exit 1; }
    echo "PEOPLE_OK  $(devname $id)  ($(wc -c < "$TREE/App/people.json" | tr -d ' ') bytes, live within ~1s)"
  fi
 ) &
done
wait
