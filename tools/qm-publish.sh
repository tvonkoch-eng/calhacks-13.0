#!/bin/bash
# qm-publish.sh — mirror the Mac hub's integration branch to GitHub.
#
#   bash tools/qm-publish.sh            # push to the GitHub branch "integration"
#   BRANCH=main bash tools/qm-publish.sh
#
# Run from a clone that has BOTH remotes: origin = the Mac hub, github = tvonkoch-eng/calhacks-13.0.
#
# github.com/tvonkoch-eng/calhacks-13.0 is PUBLIC. Everything here is a consequence of that:
#
#  * App/people.json is rewritten on the way out. The roster on the Mac carries `tie`,
#    `highlights`, `personal` and `source` — researched personal details about four real people,
#    gathered for a lens card, not for publication. Those four keys are dropped from the published
#    copy; names, roles and tags (already public in this repo) stay, so a fresh clone still builds
#    and runs. The Mac/hub copy — what actually ships to the phones — is untouched.
#  * App/References and App/Faces were already pushed to this public repo by an earlier session,
#    so they are left alone here. If that was not deliberate, the fix is to make the repo private
#    and purge the history — not something this script will do behind anyone's back.
#  * It never force-pushes and never deletes a branch. GitHub `main` carries work this tree does
#    not have (LensLab/, Tests/run.sh, tools/speed.sh); a straight push of integration over main
#    would delete it. Merge on GitHub instead.
set -eu

BRANCH=${BRANCH:-integration}
SRC=${SRC:-origin/integration}
export GH_CONFIG_DIR=${GH_CONFIG_DIR:-/root/workspace/.ghlogin-home/.config/gh}
AUTH="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$(gh auth token)" | base64 -w0)"

git fetch -q origin
git -c http.https://github.com/.extraheader="$AUTH" fetch -q github || true

# Build the published tree in a detached worktree so nothing here is disturbed.
WT=$(mktemp -d /tmp/qm-publish.XXXXXX)
trap 'rm -rf "$WT"' EXIT
git worktree add -q --detach "$WT" "$SRC"
(
  cd "$WT"
  python3 - App/people.json <<'PY'
import json, sys
path = sys.argv[1]
people = json.load(open(path))
private = ("tie", "highlights", "personal", "source")
dropped = sum(1 for p in people for k in private if k in p)
for p in people:
    for k in private:
        p.pop(k, None)
json.dump(people, open(path, "w"), indent=2, ensure_ascii=False)
open(path, "a").write("\n")
print(f"  redacted {dropped} personal field(s) across {len(people)} people")
PY
  git add App/people.json
  git -c user.email=qm@calhacks -c user.name=qm commit -q -m \
    "publish: roster without the researched personal details (this repo is public)" || true
  git -c http.https://github.com/.extraheader="$AUTH" push -q github "HEAD:refs/heads/$BRANCH"
)
git worktree remove --force "$WT" 2>/dev/null || true
echo "PUBLISHED  $SRC -> github:$BRANCH  (https://github.com/tvonkoch-eng/calhacks-13.0/tree/$BRANCH)"
