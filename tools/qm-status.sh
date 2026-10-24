#!/bin/bash
# qm-status.sh — one screen: what every agent and every phone is doing right now.
# Runs on the Mac.  bash 3.2 safe (no arrays, no ${x,,}).  Read-only.
set -u
CAL=~/calhacks
TREE=$CAL/calhacks-13.0
HUB=$CAL/calhacks.git
LOCKS=$CAL/.locks
STATE=$CAL/.state
LEDGER=$CAL/deploy-ledger.tsv
JOAQUIN=19CCB825-541A-5CC8-994B-AD337F81050D
JOAQUIN14=B598F2F8-7B4F-596D-AFDE-7360EAFD25E9
TOBY=9671B519-AC01-5E01-B9BF-99D999EAE82B
devname() { case "$1" in
  $JOAQUIN) echo "Joaquin's iPhone 17 Pro";; $JOAQUIN14) echo "Joaquin's iPhone 14 Pro";;
  $TOBY) echo "Toby's iPhone 17 Pro";; *) echo "$1";; esac; }

echo "================ CalHacks status  $(date '+%H:%M:%S %Z') ================"

if [ -f "$CAL/.demo-freeze" ]; then
  echo "!! DEMO FREEZE IS ON — every deploy will refuse.  rm ~/calhacks/.demo-freeze to resume"
fi

echo
echo "-- phones --"
CONNECTED=$(xcrun devicectl list devices 2>/dev/null)
for id in $TOBY $JOAQUIN $JOAQUIN14; do
  if echo "$CONNECTED" | grep "$id" | grep -q connected; then st="connected  "; else st="unavailable"; fi
  LAST=$(grep "	$(devname $id)	" "$LEDGER" 2>/dev/null | tail -1)
  if [ -n "$LAST" ]; then
    when=$(echo "$LAST" | cut -f1); who=$(echo "$LAST" | cut -f2)
    sha=$(echo "$LAST" | cut -f3); res=$(echo "$LAST" | cut -f6)
    printf '  %-26s %s  last: %s %s by %-12s %s\n' "$(devname $id)" "$st" "$sha" "$when" "$who" "$res"
  else
    printf '  %-26s %s  last: (never)\n' "$(devname $id)" "$st"
  fi
  TUNE=$STATE/tuning-$id.json
  if [ -f "$TUNE" ] && [ "$(cat "$TUNE")" != "{}" ]; then
    echo "      live knobs: $(cat "$TUNE")"
  fi
done

echo
echo "-- locks --"
ANY=0
for ld in "$LOCKS"/*.lock; do
  [ -d "$ld" ] || continue
  ANY=1
  age=$(( $(date +%s) - $(cat "$ld/started" 2>/dev/null || date +%s) ))
  printf '  %-18s held by %-14s %ss\n' "$(basename "$ld" .lock)" "$(cat "$ld/holder" 2>/dev/null)" "$age"
done
[ "$ANY" = 0 ] && echo "  free — nobody is building or installing"

echo
echo "-- source --"
HUBHEAD=$(git --git-dir="$HUB" rev-parse --short integration 2>/dev/null)
echo "  hub/integration  $HUBHEAD  $(git --git-dir="$HUB" log -1 --pretty='%s' integration 2>/dev/null | cut -c1-58)"
git --git-dir="$HUB" for-each-ref --format='                   %(refname:short)  %(objectname:short)  %(contents:subject)' refs/heads \
  | grep -v ' integration ' | cut -c1-96
cd "$TREE" 2>/dev/null && {
  DIRTY=$(git status --porcelain | wc -l | tr -d ' ')
  AH=$(git rev-list --count integration..HEAD 2>/dev/null || echo ?)
  BH=$(git rev-list --count HEAD..integration 2>/dev/null || echo ?)
  echo "  mac tree         $(git rev-parse --short HEAD)  ${DIRTY} uncommitted file(s), ${AH} ahead / ${BH} behind hub"
}
echo "  last built       $(cat $STATE/built.fp 2>/dev/null | cut -d- -f1)  (a deploy of this sha will skip the build)"

echo
echo "-- last 6 deploys --"
tail -6 "$LEDGER" 2>/dev/null | awk -F'\t' '{printf "  %s  %-12s %-8s %-24s built=%-3s %s\n",$1,$2,$3,$4,$5,$6}'
echo "========================================================================"
