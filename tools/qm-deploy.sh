#!/bin/bash
# qm-deploy.sh — collision-safe, fast build+deploy for CalHacks 13.0
#
# Usage:  printf '%s\n' "$MAC_KEYCHAIN_PASSWORD" | DEV="toby" AGENT=qm bash ~/calhacks/qm-deploy.sh
#
# DEV is REQUIRED (no default — a forgotten DEV must never pick a phone for you).
#   Accepts aliases: joaquin | joaquin14 | toby   — or raw devicectl ids.
#   Space-separated for several phones: DEV="toby joaquin"  -> ONE build, parallel installs.
# Optional: AGENT=<name>  FORCE_BUILD=1  NO_INSTALL=1  REF=<git ref, default hub/integration>
#           LOCK_WAIT=<sec, default 900>
#
# Design notes (why it looks like this):
#  * All source now arrives through git. Never rsync/tar over this tree again — that was the
#    only step that could silently delete another agent's work.
#  * Builds serialize behind one lock (shared ~/calhacks/dd module cache can't take two writers).
#  * The built .app is snapshotted to staging while the lock is held, so installs run fully
#    parallel — across phones and across agents — without a torn binary.
#  * Identical HEAD + Secrets => no rebuild at all. That is the fast path (~15-25 s to both phones).
set -u
set -o pipefail

CAL=~/calhacks
TREE=$CAL/calhacks-13.0
HUB=$CAL/calhacks.git
LOCKS=$CAL/.locks
STATE=$CAL/.state
LOGS=$CAL/logs
STAGE=$CAL/staging
LEDGER=$CAL/deploy-ledger.tsv
BUNDLE=com.jdelpego.calhacks13
TEAM=W9A5DGP5QJ
AGENT=${AGENT:-unknown}
REF=${REF:-hub/integration}
LOCK_WAIT=${LOCK_WAIT:-900}
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p "$LOCKS" "$STATE" "$LOGS" "$STAGE"
LOG=$LOGS/deploy-$AGENT-$TS.log
rm -f "$LOGS/latest.log"; ln -s "$LOG" "$LOGS/latest.log"
say() { echo "$@"; echo "[$(date +%H:%M:%S)] $@" >> "$LOG"; }

# Drain the keychain password from stdin immediately (never argv - ps would show it).
# Read it even when we may not build, so the caller's pipe never breaks.
PW=""
if [ ! -t 0 ]; then read -r PW || PW=""; fi

# ---------- 0. demo freeze ----------
if [ -f "$CAL/.demo-freeze" ]; then
  say "REFUSED: demo freeze is on ($(cat "$CAL/.demo-freeze" 2>/dev/null))."
  say "Clear it with: rm ~/calhacks/.demo-freeze"
  exit 9
fi

# ---------- 1. resolve devices (mandatory, validated) ----------
JOAQUIN=19CCB825-541A-5CC8-994B-AD337F81050D
JOAQUIN14=B598F2F8-7B4F-596D-AFDE-7360EAFD25E9
TOBY=9671B519-AC01-5E01-B9BF-99D999EAE82B
devname() { case "$1" in
  $JOAQUIN) echo "Joaquin's iPhone 17 Pro";; $JOAQUIN14) echo "Joaquin's iPhone 14 Pro";;
  $TOBY) echo "Toby's iPhone 17 Pro";; *) echo "$1";; esac; }

if [ -z "${DEV:-}" ]; then
  cat <<EOF
REFUSED: DEV is required — name the phone explicitly.

  DEV=joaquin     $JOAQUIN   Joaquin's iPhone 17 Pro
  DEV=joaquin14   $JOAQUIN14   Joaquin's iPhone 14 Pro
  DEV=toby        $TOBY   Toby's iPhone 17 Pro

Several at once (one build, parallel installs):  DEV="toby joaquin"
EOF
  exit 2
fi
DEVS=""
for d in $DEV; do
  case "$d" in
    joaquin|joaquin17) id=$JOAQUIN;; joaquin14) id=$JOAQUIN14;; toby) id=$TOBY;;
    *) id=$d;;
  esac
  DEVS="$DEVS $id"
done
DEVS=$(echo $DEVS | tr ' ' '\n' | awk '!seen[$0]++' | tr '\n' ' ')

CONNECTED=$(xcrun devicectl list devices 2>/dev/null)
for id in $DEVS; do
  if ! echo "$CONNECTED" | grep -q "$id"; then
    say "REFUSED: device $id is not known to this Mac."; echo "$CONNECTED"; exit 2
  fi
  if ! echo "$CONNECTED" | grep "$id" | grep -q "connected"; then
    say "REFUSED: $(devname $id) ($id) is not connected — plug it in and unlock it."
    echo "$CONNECTED"; exit 2
  fi
done
say "targets:$(for i in $DEVS; do printf ' [%s]' "$(devname $i)"; done)"

# ---------- 2. build lock ----------
BUILD_LOCK=$LOCKS/build.lock
acquire() { # $1=lockdir $2=waitsec $3=label
  local ld=$1 wait=$2 label=$3 waited=0
  while ! mkdir "$ld" 2>/dev/null; do
    local holder="$(cat "$ld/holder" 2>/dev/null)"
    local hpid="$(cat "$ld/pid" 2>/dev/null)"
    local age=$(( $(date +%s) - $(cat "$ld/started" 2>/dev/null || date +%s) ))
    if [ -n "$hpid" ] && ! kill -0 "$hpid" 2>/dev/null && [ $age -gt 30 ]; then
      say "breaking stale $label lock (holder $holder, pid $hpid gone, ${age}s old)"; rm -rf "$ld"; continue
    fi
    if [ $age -gt 1200 ]; then
      say "breaking stale $label lock (holder $holder, ${age}s old > 20m)"; rm -rf "$ld"; continue
    fi
    if [ $waited -eq 0 ]; then say "waiting for $label lock — held by $holder for ${age}s"; fi
    sleep 2; waited=$((waited+2))
    if [ $waited -ge $wait ]; then say "TIMEOUT after ${waited}s waiting for $label (holder $holder)"; return 1; fi
  done
  echo "$AGENT" > "$ld/holder"; echo $$ > "$ld/pid"; date +%s > "$ld/started"
  [ $waited -gt 0 ] && say "got $label lock after ${waited}s"
  return 0
}
HELD=""
release_all() { for l in $HELD; do rm -rf "$l"; done; }
trap release_all EXIT INT TERM

acquire "$BUILD_LOCK" "$LOCK_WAIT" "build" || exit 4
HELD="$BUILD_LOCK"

# ---------- 3. merge everything outstanding (nothing is ever discarded) ----------
cd "$TREE" || exit 1
if [ -n "$(git status --porcelain)" ]; then
  say "uncommitted edits on the Mac — committing them so the merge cannot drop them"
  git add -A
  git -c user.email=jdelpego@gmail.com -c user.name=jdelpego commit -q -m "wip: uncommitted Mac edits before $AGENT deploy $TS" >> "$LOG" 2>&1
fi
git fetch -q hub >> "$LOG" 2>&1
if ! git merge --no-edit "$REF" >> "$LOG" 2>&1; then
  git merge --abort 2>/dev/null
  say "MERGE_CONFLICT: $REF conflicts with the Mac tree. Nothing was lost or overwritten —"
  say "both versions are in git. Conflicting files:"
  git diff --name-only --diff-filter=U "$REF" 2>/dev/null | sed 's/^/  /' || true
  exit 3
fi
git push -q hub HEAD:integration >> "$LOG" 2>&1 || say "note: could not publish merge to hub (harmless)"
SHA=$(git rev-parse --short HEAD)
say "source: $SHA ($(git log -1 --pretty=%s | cut -c1-60))"

# ---------- 4. regenerate project only when project.yml moved ----------
PYHASH=$(shasum project.yml | awk '{print $1}')
if [ "$PYHASH" != "$(cat $STATE/project.yml.sha 2>/dev/null)" ] || [ ! -d CalHacks.xcodeproj ]; then
  say "project.yml changed — running xcodegen"
  ~/bin/xcodegen generate >> "$LOG" 2>&1 || { say "XCODEGEN_FAILED (see $LOG)"; exit 5; }
  echo "$PYHASH" > $STATE/project.yml.sha
  rm -f $STATE/built.fp
fi

# ---------- 5. build only if something actually changed ----------
APP=$CAL/dd/Build/Products/Debug-iphoneos/CalHacks.app
FP="$SHA-$(shasum Secrets.xcconfig 2>/dev/null | awk '{print $1}')"
BUILT=no
if [ "${FORCE_BUILD:-0}" = "1" ] || [ ! -d "$APP" ] || [ "$FP" != "$(cat $STATE/built.fp 2>/dev/null)" ]; then
  if [ -z "$PW" ]; then say "BUILD_NEEDED but no keychain password on stdin — cannot codesign"; exit 6; fi
  KC="$HOME/Library/Keychains/login.keychain-db"
  security unlock-keychain -p "$PW" "$KC" || { say "KEYCHAIN_UNLOCK_FAILED"; exit 6; }
  security set-key-partition-list -S apple-tool:,apple:,codesign:,unsigned: -s -k "$PW" "$KC" >/dev/null 2>&1 || true
  PW=""
  FIRST=$(echo $DEVS | awk '{print $1}')
  say "building ($SHA) ..."
  T0=$(date +%s)
  xcodebuild -project CalHacks.xcodeproj -scheme CalHacks -configuration Debug \
    -destination id=$FIRST -allowProvisioningUpdates \
    DEVELOPMENT_TEAM=$TEAM PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE \
    -derivedDataPath $CAL/dd build >> "$LOG" 2>&1 || { say "BUILD_FAILED — tail of $LOG:"; tail -25 "$LOG"; exit 7; }
  echo "$FP" > $STATE/built.fp
  BUILT=yes
  say "BUILD_OK ($(( $(date +%s) - T0 ))s)"
else
  say "BUILD_SKIPPED — $SHA already built (use FORCE_BUILD=1 to override)"
fi

# ---------- 6. snapshot the .app, then drop the build lock ----------
if [ "${NO_INSTALL:-0}" = "1" ]; then
  say "NO_INSTALL=1 — stopping after build. SHA=$SHA BUILT=$BUILT"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$AGENT" "$SHA" "build-only" "$BUILT" "OK" >> "$LEDGER"
  exit 0
fi
MY=$STAGE/$TS-$AGENT
mkdir -p "$MY"
ditto "$APP" "$MY/CalHacks.app" || { say "STAGE_FAILED"; exit 7; }
rm -rf "$BUILD_LOCK"; HELD=""
say "build lock released — installing in parallel"
ls -1dt $STAGE/*/ 2>/dev/null | tail -n +4 | xargs rm -rf 2>/dev/null || true

# ---------- 7. install + launch, one phone per parallel job ----------
for id in $DEVS; do
 (
  DL=$LOCKS/dev-$id.lock
  if acquire "$DL" 300 "device $(devname $id)"; then
    trap "rm -rf $DL" EXIT
    R=OK
    if xcrun devicectl device install app --device $id "$MY/CalHacks.app" >> "$LOG" 2>&1; then
      say "INSTALL_OK  $(devname $id)"
    else
      say "INSTALL_FAILED  $(devname $id)"; R=INSTALL_FAILED
    fi
    if [ "$R" = OK ]; then
      if xcrun devicectl device process launch --device $id --terminate-existing $BUNDLE >> "$LOG" 2>&1; then
        say "LAUNCH_OK   $(devname $id)"
      else
        say "LAUNCH_FAILED  $(devname $id) — if this phone is new to the profile, trust it:"
        say "   Settings > General > VPN & Device Management > Apple Development: jdelpego@gmail.com > Trust"
        R=LAUNCH_FAILED
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$AGENT" "$SHA" "$(devname $id)" "$BUILT" "$R" >> "$LEDGER"
  else
    say "DEVICE_BUSY  $(devname $id) — another agent is installing; try again"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$AGENT" "$SHA" "$(devname $id)" "$BUILT" "DEVICE_BUSY" >> "$LEDGER"
  fi
 ) &
done
wait
say "DONE  sha=$SHA built=$BUILT log=$LOG"
