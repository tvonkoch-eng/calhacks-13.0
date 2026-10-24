# Agents: how to ship here

Read this before you touch anything. It is short on purpose. Four other sessions are probably
editing this repo right now.

## The five commands

Everything runs from a sandbox clone of the hub (`/root/workspace/calhub`). Request the
credentials `tailscale:dfa15f425ebf5238` and `mac-login-keychain:292a52b4ee4f4884`.

```bash
AGENT=qm-<feature> tools/qmship --status                 # ~1s  who is building, what is on each phone
AGENT=qm-<feature> DEV=toby tools/qmship -t minGap=0.03  # ~2s  live knob change, NO build, app keeps running
AGENT=qm-<feature> tools/qmship --check -m "msg"         # ~20s commit+push+typecheck, no phone
AGENT=qm-<feature> tools/qmship --sim                    # builds, runs in the simulator, screenshots the lens
AGENT=qm-<feature> DEV=toby tools/qmship -m "msg"        # commit+push+build+install+launch
```

`DEV` is **mandatory** for anything that touches hardware: `toby` | `joaquin` | `joaquin14`,
space-separated for several. There is deliberately no default phone — a forgotten `DEV` must
never pick one for you. **Deploy only to the phone the human named.**

## The three rules

1. **Never rsync, tar or `scp` over the Mac tree.** All source moves through git. That one habit
   is the only thing that has ever silently destroyed another agent's work here.
2. **Rebase before you deploy** — `qmship` does it for you. A collision then surfaces in your own
   sandbox in a second, instead of 40 s later inside the build lock with a phone waiting.
3. **Never force-push `integration`.** On a conflict, fix the files and `git rebase --continue`.
   Nothing is ever lost: both sides are already committed.

## Before you build something, check it does not exist

Costly duplicate work has already happened twice. What is already built:

| want | use | cost |
|---|---|---|
| change a threshold, a count, a flag | `qmship -t minGap=0.03 lensHighlights=2` | ~2 s, no build, no relaunch |
| change roster text / people.json | `qmship -t people` | ~2 s, no build |
| does my Swift compile | `qmship --check` | ~9 s, no phone, no signing, own clone |
| see the lens without a phone | `qmship --sim` (+ `PREVIEW=<person id>`) | screenshot in `~/calhacks/shots/latest.png` |
| put it on a phone | `qmship -m "msg"` with `DEV=` | ~15 s warm |
| what is everyone doing | `qmship --status` | ~1 s |
| is GitHub diverging from us | `tools/qm-sync-github.sh` | — |

The app re-reads `Documents/tuning.json` once a second (`App/Tuning.swift`), which is why the
knob path needs no rebuild. **If you are tuning numbers or copy, you should almost never be
building.**

## Where things live

- `~/calhacks/calhacks.git` — bare hub on the Mac, branch `integration`. The source of truth.
- `~/calhacks/calhacks-13.0` — the Mac's build tree. `qm-deploy.sh` merges the hub into it.
- `~/calhacks/qm-deploy.sh` — the one entry point for builds. `tools/qm-deploy.sh` is the versioned copy.
- `~/calhacks/logs/latest.log`, `~/calhacks/deploy-ledger.tsv` — every build, every install, who did it.
- `Secrets.xcconfig` is gitignored and Mac-local. Never commit it.
- `tools/qm-mac-ssh.sh` — multiplexed ssh. Source it; do not hand-roll an `ssh` line. A cold
  connection costs ~5 s and an iteration used to open three of them.

## Traps that have each cost an hour

- `ssh` without `-e none` **silently truncates piped data** and still reports success. Always
  `md5` both ends after a file transfer.
- `ssh host 'cmd > dest'` truncates `dest` *before* `cmd` runs. Write to a temp file, then `mv`.
- The Mac's non-interactive shell is **zsh**, and its bash is **3.2** — no arrays under `set -u`.
- macOS `base64` is `base64 -D -i in -o out`. There is no `timeout(1)`.
- `project.yml` uses `sources: [App]`, so **adding any file** (including a reference photo)
  changes the project. `qm-deploy.sh` fingerprints the whole file list, so this is handled —
  but if you add files outside it, re-run `~/bin/xcodegen generate`.
- A new phone must trust the developer profile by hand once:
  Settings → General → VPN & Device Management → Apple Development → Trust. Install works
  without it; only launch fails.
- The signing profile is a free personal team: it **expires 7 days** after the build.

## Demo protection

`touch ~/calhacks/.demo-freeze` makes every deploy refuse, loudly. Do this before the human
walks on stage. `rm` it to resume.
