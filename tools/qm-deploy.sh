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
# Three modes:
#   (default)  build + install + launch on the named phone(s).
#   CHECK=1    typecheck only. No phone, no signing, no keychain, no build lock, no DEV — it runs
#              in its own clone (check-tree) with its own derived data, so it cannot disturb a
#              build another agent is running. ~5 s warm. Push to the hub first: it checks REF.
#   SIM=1      build and run in the iOS Simulator and grab a screenshot of the lens. No phone, no
#              signing, no keychain, no 7-day profile expiry. SIM="iPhone 16" picks another sim.
#              PREVIEW=<person id> brings the app up with that identity card already on the lens.
#
# Design notes (why it looks like this):
#  * All source now arrives through git. Never rsync/tar over this tree again — that was the
#    only step that could silently delete another agent's work.
#  * Builds serialize behind one lock (shared ~/calhacks/dd module cache can't take two writers).
#  * The built .app is snapshotted to staging while the lock is held, so installs run fully
#    parallel — across phones and across agents — without a torn binary.
#  * Identical HEAD + Secrets => no rebuild at all. That is the fast path (~5 s to one phone).
#  * Package resolution is pinned, not re-resolved: Xcode spent ~4 s of every 9 s build asking
#    GitHub about a dependency whose version is already written down in Package.resolved.
set -u
set -o pipefail

CAL=~/calhacks
TREE=$CAL/calhacks-13.0
HUB=$CAL/calhacks.git
LOCKS=$CAL/.locks
STATE=$CAL/.state
LOGS=$CAL/logs
STAGE=$CAL/staging
SHOTS=$CAL/shots
LEDGER=$CAL/deploy-ledger.tsv
BUNDLE=com.jdelpego.calhacks13
TEAM=W9A5DGP5QJ
AGENT=${AGENT:-unknown}
REF=${REF:-hub/integration}
LOCK_WAIT=${LOCK_WAIT:-900}
TS=$(date +%Y%m%d-%H%M%S)
SWIFTPM=CalHacks.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p "$LOCKS" "$STATE" "$LOGS" "$STAGE" "$SHOTS"
LOG=$LOGS/deploy-$AGENT-$TS.log
rm -f "$LOGS/latest.log"; ln -s "$LOG" "$LOGS/latest.log"
say() { echo "$@"; echo "[$(date +%H:%M:%S)] $@" >> "$LOG"; }

# Don't re-resolve a dependency graph that is already pinned, and don't build the index store for
# a machine with no Xcode UI open on this project. Together: ~4 s off every build.
FAST="-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile"
FASTSET="COMPILER_INDEX_STORE_ENABLE=NO"
UNSIGNED="CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= CODE_SIGN_ENTITLEMENTS="

# xcodegen with `sources: [App]` writes an explicit reference per file, so ADDING a source file
# or a reference photo changes the project even though project.yml does not. Fingerprint both, or
# a new file is silently left out of the build and the compiler says "cannot find X in scope".
layout_fp() {
  { shasum project.yml; find App Tests -type f ! -name '.DS_Store' 2>/dev/null | sort; } \
    | shasum | awk '{print $1}'
}

errors_from_log() {
  grep -E "(error|warning): " "$LOG" | grep -v "appintentsmetadataprocessor" | tail -25
}

# Drain the keychain password from stdin immediately (never argv - ps would show it).
# Read it even when we may not build, so the caller's pipe never breaks.
PW=""
if [ ! -t 0 ]; then read -r PW || PW=""; fi

# ---------- 0a. CHECK: typecheck in an isolated clone; no lock, no phone, no signing ----------
if [ "${CHECK:-0}" = "1" ]; then
  CT=$CAL/check-tree
  CREF=${REF#hub/}
  if [ ! -d "$CT/.git" ]; then
    say "first check — cloning the hub into $CT (one-off, the build after this one is incremental)"
    git clone -q --shared "$HUB" "$CT" >> "$LOG" 2>&1 || { say "CHECK_CLONE_FAILED"; exit 8; }
  fi
  cd "$CT" || exit 1
  git fetch -q origin >> "$LOG" 2>&1
  git reset -q --hard "origin/$CREF" >> "$LOG" 2>&1 \
    || git reset -q --hard "$CREF" >> "$LOG" 2>&1 \
    || { say "CHECK_REF_FAILED: no such ref $CREF on the hub (push first)"; exit 8; }
  CSHA=$(git rev-parse --short HEAD)
  # Secrets.xcconfig is Mac-local and gitignored; the example has the same keys with empty values,
  # which is all a typecheck needs.
  cp -f "$TREE/Secrets.xcconfig" Secrets.xcconfig 2>/dev/null || cp -f Secrets.example.xcconfig Secrets.xcconfig
  PYHASH=$(layout_fp)
  if [ "$PYHASH" != "$(cat $STATE/check.project.yml.sha 2>/dev/null)" ] || [ ! -d CalHacks.xcodeproj ]; then
    ~/bin/xcodegen generate >> "$LOG" 2>&1 || { say "CHECK_XCODEGEN_FAILED"; exit 8; }
    echo "$PYHASH" > $STATE/check.project.yml.sha
  fi
  # xcodegen makes a fresh .xcodeproj with no Package.resolved in it, and without one the pinned
  # -onlyUsePackageVersionsFromResolvedFile build has nothing to read. Borrow the real tree's.
  mkdir -p "$SWIFTPM" && cp -f "$TREE/$SWIFTPM/Package.resolved" "$SWIFTPM/" 2>/dev/null || true
  say "typechecking $CSHA — no phone, no signing, no lock"
  T0=$(date +%s)
  if xcodebuild -project CalHacks.xcodeproj -scheme CalHacks -configuration Debug \
      -destination 'generic/platform=iOS' -derivedDataPath $CAL/dd-check \
      $FAST $FASTSET $UNSIGNED build >> "$LOG" 2>&1; then
    say "CHECK_OK  $CSHA  ($(( $(date +%s) - T0 ))s)"
    exit 0
  fi
  say "CHECK_FAILED  $CSHA  ($(( $(date +%s) - T0 ))s) — compiler says:"
  errors_from_log
  exit 8
fi

# ---------- 0b. demo freeze ----------
if [ -f "$CAL/.demo-freeze" ]; then
  say "REFUSED: demo freeze is on ($(cat "$CAL/.demo-freeze" 2>/dev/null))."
  say "Clear it with: rm ~/calhacks/.demo-freeze"
  exit 9
fi

SIMMODE=0
[ -n "${SIM:-}" ] && [ "${SIM:-}" != "0" ] && SIMMODE=1

# ---------- 1. resolve devices (mandatory, validated) ----------
JOAQUIN=19CCB825-541A-5CC8-994B-AD337F81050D
JOAQUIN14=B598F2F8-7B4F-596D-AFDE-7360EAFD25E9
TOBY=9671B519-AC01-5E01-B9BF-99D999EAE82B
devname() { case "$1" in
  $JOAQUIN) echo "Joaquin's iPhone 17 Pro";; $JOAQUIN14) echo "Joaquin's iPhone 14 Pro";;
  $TOBY) echo "Toby's iPhone 17 Pro";; *) echo "$1";; esac; }

DEVS=""
if [ "$SIMMODE" = "0" ]; then
  if [ -z "${DEV:-}" ]; then
    cat <<EOF
REFUSED: DEV is required — name the phone explicitly.

  DEV=joaquin     $JOAQUIN   Joaquin's iPhone 17 Pro
  DEV=joaquin14   $JOAQUIN14   Joaquin's iPhone 14 Pro
  DEV=toby        $TOBY   Toby's iPhone 17 Pro

Several at once (one build, parallel installs):  DEV="toby joaquin"
No phone at all:  CHECK=1 (typecheck)   SIM=1 (simulator + screenshot)
EOF
    exit 2
  fi
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
else
  [ -n "${DEV:-}" ] && { say "REFUSED: SIM and DEV together is ambiguous — pick one."; exit 2; }
  SIMNAME=${SIM}
  [ "$SIMNAME" = "1" ] && SIMNAME="iPhone 16 Pro"
  SIMID=$(xcrun simctl list devices available | grep -F "$SIMNAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
  if [ -z "$SIMID" ]; then
    say "REFUSED: no available simulator named '$SIMNAME'."
    xcrun simctl list devices available | sed 's/^/  /'; exit 2
  fi
  say "target: [$SIMNAME simulator $SIMID]"
fi

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

# ---------- 3b. reference photos published on GitHub ----------
# People add faces by pushing them to github.com/tvonkoch-eng/calhacks-13.0, which is NOT the hub
# this Mac builds from — so photos landed in the repo and never reached a phone. Take the photo
# directories from GitHub (public, read-only, no auth) and nothing else: that repo's Swift and its
# people.json are older than ours, and merging the branch would roll the app back.
# GHSYNC=0 skips it; a GitHub outage is never allowed to block a deploy.
if [ "${GHSYNC:-1}" = "1" ]; then
  git remote get-url github >/dev/null 2>&1 || \
    git remote add github https://github.com/tvonkoch-eng/calhacks-13.0.git >> "$LOG" 2>&1
  GHREF=${GHREF:-github/main}
  if git fetch -q --depth=1 github main >> "$LOG" 2>&1; then
    git checkout "$GHREF" -- App/References App/Faces >> "$LOG" 2>&1 || true
    if [ -n "$(git status --porcelain App/References App/Faces)" ]; then
      NEW=$(git status --porcelain App/References App/Faces | awk '{print $NF}' | xargs -n1 basename 2>/dev/null | tr '\n' ' ')
      say "photos from GitHub: $NEW"
      git add App/References App/Faces
      git -c user.email=jdelpego@gmail.com -c user.name=jdelpego \
        commit -q -m "photos: sync App/References+Faces from github/main ($AGENT $TS)" >> "$LOG" 2>&1
      git push -q hub HEAD:integration >> "$LOG" 2>&1 || say "note: could not publish photo sync to hub"
      SHA=$(git rev-parse --short HEAD)
      say "source: $SHA (after GitHub photo sync)"
    else
      say "photos: already in step with github/main"
    fi
  else
    say "note: could not reach GitHub for photos — building with the photos already here"
  fi
fi

# ---------- 3c. face embedding model (gitignored, licence-restricted) ----------
# MobileFaceNet/ArcFace weights: non-commercial research use only, so they are NOT in the repo and
# NOT in the public GitHub mirror. They live on this Mac and are copied into App/ for the build.
# Absent is not an error — the app falls back to the Vision feature print and says so in its log.
MODEL_SRC=$CAL/models/MobileFaceNet_w600k.mlmodel
if [ -f "$MODEL_SRC" ]; then
  if ! cmp -s "$MODEL_SRC" App/MobileFaceNet_w600k.mlmodel 2>/dev/null; then
    cp "$MODEL_SRC" App/MobileFaceNet_w600k.mlmodel
    say "face model: copied into App/ ($(du -h App/MobileFaceNet_w600k.mlmodel | cut -f1))"
  fi
else
  say "face model: NOT PRESENT at $MODEL_SRC — build will fall back to the Vision feature print"
fi
# SCRFD-500M face detector, same licence and same rule. Absent = the app uses Vision's detector.
DET_SRC=$CAL/models/SCRFD_500M.mlpackage
if [ -d "$DET_SRC" ]; then
  if ! diff -rq "$DET_SRC" App/SCRFD_500M.mlpackage >/dev/null 2>&1; then
    rm -rf App/SCRFD_500M.mlpackage && cp -R "$DET_SRC" App/SCRFD_500M.mlpackage
    say "face detector: copied SCRFD_500M.mlpackage into App/"
  fi
else
  say "face detector: NOT PRESENT at $DET_SRC — build will fall back to Vision's detector"
fi

# ---------- 4. regenerate project only when project.yml moved ----------
PYHASH=$(layout_fp)
if [ "$PYHASH" != "$(cat $STATE/project.yml.sha 2>/dev/null)" ] || [ ! -d CalHacks.xcodeproj ]; then
  say "project layout changed (project.yml or the file list) — running xcodegen"
  cp -f "$SWIFTPM/Package.resolved" /tmp/qm-package.resolved 2>/dev/null || true
  ~/bin/xcodegen generate >> "$LOG" 2>&1 || { say "XCODEGEN_FAILED (see $LOG)"; exit 5; }
  # Keep the pin across a regenerate, or the next build falls back to asking GitHub.
  mkdir -p "$SWIFTPM"; cp -f /tmp/qm-package.resolved "$SWIFTPM/Package.resolved" 2>/dev/null || true
  echo "$PYHASH" > $STATE/project.yml.sha
  rm -f $STATE/built.fp $STATE/built-sim.fp
fi
[ -f "$SWIFTPM/Package.resolved" ] || FAST=""   # nothing to pin against: let Xcode resolve once

# ---------- 5. build only if something actually changed ----------
if [ "$SIMMODE" = "1" ]; then
  APP=$CAL/dd-sim/Build/Products/Debug-iphonesimulator/CalHacks.app
  FPFILE=$STATE/built-sim.fp
else
  APP=$CAL/dd/Build/Products/Debug-iphoneos/CalHacks.app
  FPFILE=$STATE/built.fp
fi
FP="$SHA-$(shasum Secrets.xcconfig 2>/dev/null | awk '{print $1}')"
BUILT=no
if [ "${FORCE_BUILD:-0}" = "1" ] || [ ! -d "$APP" ] || [ "$FP" != "$(cat $FPFILE 2>/dev/null)" ]; then
  T0=$(date +%s)
  if [ "$SIMMODE" = "1" ]; then
    say "building for the simulator ($SHA) — no signing, no keychain ..."
    xcodebuild -project CalHacks.xcodeproj -scheme CalHacks -configuration Debug \
      -destination "id=$SIMID" $FAST $FASTSET $UNSIGNED \
      PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE \
      -derivedDataPath $CAL/dd-sim build >> "$LOG" 2>&1 \
      || { say "BUILD_FAILED — compiler says:"; errors_from_log; exit 7; }
  else
    if [ -z "$PW" ]; then say "BUILD_NEEDED but no keychain password on stdin — cannot codesign"; exit 6; fi
    KC="$HOME/Library/Keychains/login.keychain-db"
    security unlock-keychain -p "$PW" "$KC" || { say "KEYCHAIN_UNLOCK_FAILED"; exit 6; }
    security set-key-partition-list -S apple-tool:,apple:,codesign:,unsigned: -s -k "$PW" "$KC" >/dev/null 2>&1 || true
    PW=""
    FIRST=$(echo $DEVS | awk '{print $1}')
    say "building ($SHA) ..."
    xcodebuild -project CalHacks.xcodeproj -scheme CalHacks -configuration Debug \
      -destination id=$FIRST -allowProvisioningUpdates $FAST $FASTSET \
      DEVELOPMENT_TEAM=$TEAM PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE \
      -derivedDataPath $CAL/dd build >> "$LOG" 2>&1 \
      || { say "BUILD_FAILED — compiler says:"; errors_from_log; exit 7; }
  fi
  echo "$FP" > $FPFILE
  BUILT=yes
  say "BUILD_OK ($(( $(date +%s) - T0 ))s)"
else
  say "BUILD_SKIPPED — $SHA already built (use FORCE_BUILD=1 to override)"
fi

# ---------- 5b. every person on the roster must have their photos IN the bundle ----------
# The whole chain is repo -> xcodegen -> bundle -> embedding, and the quiet failure is a photo
# that exists in the repo and never makes it into CalHacks.app, which on the phone looks exactly
# like "the face matcher is bad". Count both ends and say so out loud; refuse to install a build
# that dropped someone's photos.
PHOTOLINE=""
MISSING=""
for pid in $(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' App/people.json); do
  REPO=$(ls App/References 2>/dev/null | grep -c -iE "^${pid}_.*\.(jpg|jpeg|png|heic)$")
  INAPP=$(ls "$APP" 2>/dev/null | grep -c -iE "^${pid}_.*\.(jpg|jpeg|png|heic)$")
  PHOTOLINE="$PHOTOLINE $pid:$INAPP/$REPO"
  [ "$INAPP" -lt "$REPO" ] && MISSING="$MISSING $pid"
  [ "$REPO" -eq 0 ] && MISSING="$MISSING $pid(none-in-repo)"
done
say "photos in bundle (bundled/repo):$PHOTOLINE"
if [ -n "$MISSING" ]; then
  say "ASSETS_MISSING:$MISSING — the build does not carry every reference photo."
  say "   Usually a stale CalHacks.xcodeproj: run ~/bin/xcodegen generate, then FORCE_BUILD=1."
  exit 7
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

# ---------- 7a. simulator: boot, install, launch, screenshot ----------
if [ "$SIMMODE" = "1" ]; then
  xcrun simctl bootstatus "$SIMID" -b >> "$LOG" 2>&1 || xcrun simctl boot "$SIMID" >> "$LOG" 2>&1
  xcrun simctl bootstatus "$SIMID" >> "$LOG" 2>&1
  xcrun simctl install "$SIMID" "$MY/CalHacks.app" >> "$LOG" 2>&1 \
    || { say "INSTALL_FAILED  simulator"; tail -15 "$LOG"; exit 7; }
  say "INSTALL_OK  $SIMNAME"
  # The app reads MOCK_GLASSES / PREVIEW_PERSON from its environment; simctl passes anything
  # prefixed SIMCTL_CHILD_ straight through.
  export SIMCTL_CHILD_MOCK_GLASSES=${MOCK_GLASSES:-1}
  [ -n "${PREVIEW:-}" ] && export SIMCTL_CHILD_PREVIEW_PERSON="$PREVIEW" && export SIMCTL_CHILD_PREVIEW_CONFIRM=${PREVIEW_CONFIRM:-1}
  [ -n "${PREVIEW_SEEN:-}" ] && export SIMCTL_CHILD_PREVIEW_SEEN="$PREVIEW_SEEN"
  xcrun simctl terminate "$SIMID" $BUNDLE >/dev/null 2>&1 || true
  xcrun simctl launch "$SIMID" $BUNDLE >> "$LOG" 2>&1 \
    || { say "LAUNCH_FAILED  simulator"; tail -15 "$LOG"; exit 7; }
  say "LAUNCH_OK   $SIMNAME"
  sleep ${SHOT_DELAY:-6}
  SHOT=$SHOTS/sim-$TS.png
  xcrun simctl io "$SIMID" screenshot "$SHOT" >> "$LOG" 2>&1 \
    && { rm -f $SHOTS/latest.png; ln -s "$SHOT" $SHOTS/latest.png; say "SHOT $SHOT"; } \
    || say "SHOT_FAILED"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$AGENT" "$SHA" "simulator $SIMNAME" "$BUILT" "OK" >> "$LEDGER"
  say "DONE  sha=$SHA built=$BUILT shot=$SHOT log=$LOG"
  exit 0
fi

# ---------- 7b. install + launch, one phone per parallel job ----------
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
