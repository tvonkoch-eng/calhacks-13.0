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
#  * It never force-pushes. GitHub `main` carries work this tree does not have (LensLab/,
#    Tests/run.sh, tools/speed.sh) and shares NO history with the Mac hub, so a straight push
#    would delete it. Instead the published commit merges github/main in with `-X ours`: anything
#    that exists only on main is carried along untouched, and on overlap this tree wins. The
#    result has main as a parent, so the push is an ordinary fast-forward every time.
#    Files where main differed and we overrode it are printed — check that list.
set -eu

BRANCH=${BRANCH:-main}
SRC=${SRC:-origin/integration}
export GH_CONFIG_DIR=${GH_CONFIG_DIR:-/root/workspace/.ghlogin-home/.config/gh}
AUTH="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$(gh auth token)" | base64 -w0)"

git fetch -q origin || true
git -c http.https://github.com/.extraheader="$AUTH" fetch -q github || true

# Nothing new since the last mirror? Say nothing and stop — this runs on a timer, so the quiet
# path has to be genuinely quiet.
SRCSHA=$(git rev-parse "$SRC")
MARK=${MARK:-/root/workspace/.qm-publish-state}
if [ "${FORCE:-0}" != "1" ] && [ "$SRCSHA" = "$(cat "$MARK" 2>/dev/null)" ]; then
  echo "UP_TO_DATE  $SRC is already mirrored ($(git rev-parse --short "$SRC"))"
  exit 0
fi

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

  if git rev-parse -q --verify github/$BRANCH >/dev/null; then
    # Say out loud what this tree is about to overrule, so a quiet loss is impossible.
    # Only files that exist on BOTH sides and differ are genuine overrides. A plain
    # `git diff --name-only` also lists everything missing from one side, which reads as though
    # the merge is about to clobber work it is in fact carrying over.
    IN_BOTH=$(comm -12 <(git ls-tree -r --name-only HEAD | sort) \
                       <(git ls-tree -r --name-only github/$BRANCH | sort))
    OVERRIDDEN=$(git diff --name-only HEAD github/$BRANCH | grep -Fx -f <(echo "$IN_BOTH") | head -20)
    ONLY_THERE=$(comm -13 <(git ls-tree -r --name-only HEAD | sort) \
                          <(git ls-tree -r --name-only github/$BRANCH | sort))
    [ -n "$ONLY_THERE" ] && echo "  carrying over $(echo "$ONLY_THERE" | wc -l | tr -d ' ') file(s) that exist only on $BRANCH"
    git -c user.email=qm@calhacks -c user.name=qm merge --no-edit --allow-unrelated-histories \
        -X ours github/$BRANCH -m "merge github/$BRANCH (keeps anything only on $BRANCH; the Mac hub wins on overlap)" -q
    if [ -n "$OVERRIDDEN" ]; then
      echo "  this tree overruled $BRANCH on:"; echo "$OVERRIDDEN" | sed 's/^/    /'
    fi
    # Nothing that was on the branch may vanish.
    LOST=$(comm -13 <(git ls-tree -r --name-only HEAD | sort) \
                    <(git ls-tree -r --name-only github/$BRANCH | sort))
    if [ -n "$LOST" ]; then
      echo "REFUSED: the merge would drop files that are on $BRANCH:"; echo "$LOST" | sed 's/^/    /'
      exit 1
    fi
  fi
  git -c http.https://github.com/.extraheader="$AUTH" push -q github "HEAD:refs/heads/$BRANCH"
)
git worktree remove --force "$WT" 2>/dev/null || true
echo "$SRCSHA" > "$MARK"
echo "PUBLISHED  $SRC -> github:$BRANCH  (https://github.com/tvonkoch-eng/calhacks-13.0/tree/$BRANCH)"
