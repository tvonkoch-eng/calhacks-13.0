#!/usr/bin/env bash
#
# qm-sync-github.sh — keep the Mac hub and the public GitHub repo visible to each other.
#
# Run this FROM THE SANDBOX (it needs both the tailscale route to the Mac and gh/https
# access to GitHub). It is deliberately boring:
#
#   * fetches both remotes
#   * pushes hub `integration` to GitHub as `integration`      (never main, never --force)
#   * mirrors `github/main` into the hub as `github-main`      (a ref only; nothing is merged)
#   * prints a divergence report so the next agent can see at a glance whether a human
#     change on GitHub has never been built for the phones
#
# It never checks anything out, never merges, never rewrites history, and never touches a
# local branch. The only ref it creates or moves is `github-main` on the hub.
#
# Exit codes
#   0  in sync (or already up to date)
#   1  bad environment / usage
#   2  a fetch failed
#   3  a push was rejected (non-fast-forward) — reported, NOT forced
#   4  the GitHub push was skipped because the roster carries personal data and the
#      GitHub repo is public (override with QM_SYNC_ALLOW_PERSONAL=1)
#
# Env
#   QM_SYNC_REPO            clone to work in           (default /root/workspace/calhub)
#   QM_SYNC_HUB_BRANCH      branch on the hub          (default integration)
#   QM_SYNC_GH_BRANCH       branch to publish on GitHub(default integration)
#   QM_SYNC_NO_PUSH=1       report only; push nothing
#   QM_SYNC_ALLOW_PERSONAL=1  publish even if App/people.json carries personal fields
#
set -uo pipefail

REPO="${QM_SYNC_REPO:-/root/workspace/calhub}"
HUB_BRANCH="${QM_SYNC_HUB_BRANCH:-integration}"
GH_BRANCH="${QM_SYNC_GH_BRANCH:-integration}"
MIRROR_REF="github-main"
MAC_KEY="${QM_SYNC_SSH_KEY:-/root/.ssh/qm_mac}"

status=0
note()  { printf '%s\n' "$*"; }
warn()  { printf '!! %s\n' "$*" >&2; }
fail()  { printf 'XX %s\n' "$*" >&2; }
rule()  { printf '\n== %s ==\n' "$*"; }

# ---------------------------------------------------------------- environment

# tailscale lives outside the default PATH on this sandbox, and the hub is only
# reachable through it (tailscaled here is userspace-networking, hence ProxyCommand).
case ":$PATH:" in *:/usr/local/bin:*) ;; *) PATH="$PATH:/usr/local/bin" ;; esac
export PATH

if [ -z "${GIT_SSH_COMMAND:-}" ]; then
  if [ ! -r "$MAC_KEY" ]; then
    fail "no ssh key at $MAC_KEY and GIT_SSH_COMMAND is unset — cannot reach the Mac hub"
    exit 1
  fi
  # -e none is mandatory: without it ssh silently truncates the git stream.
  export GIT_SSH_COMMAND="ssh -e none -i $MAC_KEY -o ProxyCommand=\"tailscale nc %h %p\" -o BatchMode=yes"
fi

[ -d "$REPO/.git" ] || { fail "not a git clone: $REPO"; exit 1; }
git -C "$REPO" remote get-url origin >/dev/null 2>&1 || { fail "no 'origin' remote (the Mac hub) in $REPO"; exit 1; }
git -C "$REPO" remote get-url github >/dev/null 2>&1 || { fail "no 'github' remote in $REPO"; exit 1; }

g() { git -C "$REPO" "$@"; }

note "repo   : $REPO"
note "origin : $(g remote get-url origin)   (Mac hub — what the phones build)"
note "github : $(g remote get-url github)   (human teammates)"

# ---------------------------------------------------------------- fetch both

rule "fetch"
if ! g fetch --prune --no-tags origin 2>&1; then
  fail "fetch from the Mac hub failed (tailscale credential expired, or the Mac is asleep/off the tailnet)"
  exit 2
fi
if ! g fetch --prune --no-tags github 2>&1; then
  fail "fetch from GitHub failed (gh/https auth — try HOME=/root/workspace/.ghlogin-home)"
  exit 2
fi

HUB="$(g rev-parse --verify --quiet "refs/remotes/origin/$HUB_BRANCH")" || true
GHM="$(g rev-parse --verify --quiet "refs/remotes/github/main")" || true
GHB="$(g rev-parse --verify --quiet "refs/remotes/github/$GH_BRANCH" || true)"

[ -n "$HUB" ] || { fail "hub has no branch '$HUB_BRANCH'"; exit 1; }
[ -n "$GHM" ] || { fail "GitHub has no branch 'main'"; exit 1; }

note "hub  origin/$HUB_BRANCH = $(g log -1 --format='%h %ad %s' --date=iso-local "$HUB")"
note "gh   github/main        = $(g log -1 --format='%h %ad %s' --date=iso-local "$GHM")"
[ -n "$GHB" ] && note "gh   github/$GH_BRANCH = $(g log -1 --format='%h %ad %s' --date=iso-local "$GHB")"

# ------------------------------------------------- privacy gate (public repo)

rule "privacy check"
gh_url="$(g remote get-url github)"
gh_public=unknown
slug="$(printf '%s' "$gh_url" | sed -e 's#.*github\.com[:/]##' -e 's#\.git$##')"
if command -v gh >/dev/null 2>&1; then
  vis="$(HOME="${QM_SYNC_GH_HOME:-/root/workspace/.ghlogin-home}" \
         GH_CONFIG_DIR="${QM_SYNC_GH_HOME:-/root/workspace/.ghlogin-home}/.config/gh" \
         gh repo view "$slug" --json visibility -q .visibility 2>/dev/null)"
  case "$vis" in PUBLIC) gh_public=yes ;; PRIVATE|INTERNAL) gh_public=no ;; esac
fi
note "github repo visibility: $gh_public"

personal_fields=""
if g cat-file -e "$HUB:App/people.json" 2>/dev/null; then
  for f in personal work highlights tie source; do
    if g show "$HUB:App/people.json" | grep -q "\"$f\"[[:space:]]*:"; then
      personal_fields="$personal_fields $f"
    fi
  done
fi
push_blocked_by_privacy=0
if [ -n "$personal_fields" ] && [ "$gh_public" = "yes" ]; then
  warn "App/people.json on the hub carries researched personal fields:$personal_fields"
  warn "and $slug is a PUBLIC repo. Publishing it is irreversible."
  if [ "${QM_SYNC_ALLOW_PERSONAL:-0}" != "1" ]; then
    warn "skipping the GitHub push. Re-run with QM_SYNC_ALLOW_PERSONAL=1 to publish anyway,"
    warn "or scrub the roster on the hub first."
    push_blocked_by_privacy=1
    status=4
  else
    warn "QM_SYNC_ALLOW_PERSONAL=1 set — publishing anyway."
  fi
else
  note "no public-repo/personal-data conflict detected."
fi

# -------------------------------------------- push hub integration -> GitHub

rule "push hub $HUB_BRANCH -> github $GH_BRANCH"
if [ "${QM_SYNC_NO_PUSH:-0}" = "1" ]; then
  note "QM_SYNC_NO_PUSH=1 — skipped."
elif [ "$push_blocked_by_privacy" = "1" ]; then
  note "skipped (see privacy check above)."
elif [ "$GH_BRANCH" = "main" ] || [ "$GH_BRANCH" = "master" ]; then
  fail "refusing to push to '$GH_BRANCH' — this script never writes the humans' default branch"
  exit 1
elif [ -n "$GHB" ] && [ "$GHB" = "$HUB" ]; then
  note "already up to date ($(git -C "$REPO" rev-parse --short "$HUB"))."
else
  # Explicit sha:ref refspec. No +, no --force, ever.
  out="$(g push github "$HUB:refs/heads/$GH_BRANCH" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  if [ $rc -ne 0 ]; then
    if printf '%s' "$out" | grep -qi 'non-fast-forward\|fetch first\|stale info\|rejected'; then
      fail "push REJECTED as non-fast-forward — github/$GH_BRANCH has commits the hub does not."
      if [ -n "$GHB" ]; then
        fail "commits on github/$GH_BRANCH missing from the hub:"
        g log --format='    %h %an  %s' "$HUB..$GHB" >&2
        fail "nothing was forced. Merge or cherry-pick those into the hub, then re-run."
      fi
      status=3
    else
      fail "push to GitHub failed (see output above)."
      status=3
    fi
  fi
fi

# ------------------------------- mirror github/main into the hub as a ref only

rule "mirror github/main -> hub $MIRROR_REF"
HUBMIRROR="$(g ls-remote --heads origin "$MIRROR_REF" 2>/dev/null | awk '{print $1}')"
if [ "${QM_SYNC_NO_PUSH:-0}" = "1" ]; then
  note "QM_SYNC_NO_PUSH=1 — skipped."
elif [ "$HUBMIRROR" = "$GHM" ]; then
  note "hub $MIRROR_REF already at $(g rev-parse --short "$GHM")."
else
  out="$(g push origin "refs/remotes/github/main:refs/heads/$MIRROR_REF" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  if [ $rc -ne 0 ]; then
    if printf '%s' "$out" | grep -qi 'non-fast-forward\|rejected'; then
      fail "hub '$MIRROR_REF' could not be fast-forwarded — github/main was rewritten."
      fail "NOT forcing. Delete the hub ref deliberately if that rewrite is intended."
      status=3
    else
      fail "could not update hub '$MIRROR_REF' (see output above)."
      status=3
    fi
  else
    note "hub can now see the humans' main at refs/heads/$MIRROR_REF (nothing merged)."
  fi
fi

# ---------------------------------------------------------------- divergence

rule "divergence: github/main  vs  hub/$HUB_BRANCH"

base="$(g merge-base "$GHM" "$HUB" 2>/dev/null || true)"
if [ -n "$base" ]; then
  note "merge base: $(g log -1 --format='%h %ad %s' --date=iso-local "$base")"
else
  note "merge base: NONE — the two histories are unrelated (the hub was seeded from a"
  note "            working-tree snapshot, not cloned from GitHub). Commit counts below"
  note "            are therefore whole-history counts, not 'ahead/behind'."
fi

counts="$(g rev-list --left-right --count "$GHM...$HUB")"
gh_only="$(printf '%s' "$counts" | cut -f1)"
hub_only="$(printf '%s' "$counts" | cut -f2)"
note "commits only on github/main : $gh_only"
note "commits only on hub/$HUB_BRANCH : $hub_only"

if [ "$gh_only" != "0" ]; then
  note ""
  note "most recent commits on github/main:"
  g log --format='    %h %ad %an  %s' --date=short -8 "$GHM" ${base:+"^$base"}
fi

note ""
note "files that differ (github/main -> hub/$HUB_BRANCH):"
diffs="$(g diff --name-status "$GHM" "$HUB")"
if [ -z "$diffs" ]; then
  note "    (none — trees are identical)"
else
  printf '%s\n' "$diffs" | sed 's/^/    /'
fi

# The dangerous set: content the humans have that the phones have never built.
note ""
only_gh="$(printf '%s\n' "$diffs" | awk -F'\t' '$1=="D"{print $2}')"
if [ -n "$only_gh" ]; then
  warn "PRESENT ON GITHUB, ABSENT FROM THE HUB — the phones have never built these:"
  printf '%s\n' "$only_gh" | sed 's/^/    /' >&2
  # Did they ever exist on the hub branch at all?
  note ""
  note "    (checking whether these were ever on hub/$HUB_BRANCH...)"
  ever=0
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if [ -n "$(g log --oneline -1 "$HUB" -- "$p" 2>/dev/null)" ]; then
      note "    was once on the hub, now deleted: $p"
      ever=1
    fi
  done <<EOF
$only_gh
EOF
  [ "$ever" = "0" ] && note "    none of them ever existed on hub/$HUB_BRANCH — never deleted, just never carried over."
else
  note "nothing exists on github/main that is missing from the hub."
fi

only_hub="$(printf '%s\n' "$diffs" | awk -F'\t' '$1=="A"{print $2}' | wc -l | tr -d ' ')"
modified="$(printf '%s\n' "$diffs" | awk -F'\t' '$1 ~ /^M/{print $2}' | wc -l | tr -d ' ')"
note ""
note "summary: $only_hub file(s) only on the hub, $modified modified on both sides,"
note "         $(printf '%s\n' "$only_gh" | grep -c . ) file(s) only on GitHub."

rule "result"
case $status in
  0) note "OK — hub published to github/$GH_BRANCH, github/main mirrored to hub/$MIRROR_REF." ;;
  3) note "PROBLEM — a push was rejected. Nothing was forced. See above." ;;
  4) note "BLOCKED — GitHub push skipped to avoid publishing personal data to a public repo." ;;
esac
exit $status
