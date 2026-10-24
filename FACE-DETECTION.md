# Face detection (branch `face-scrfd`): handoff for merging with the conversation aid

Automatic face recognition on the glasses, tuned on Toby's phone + glasses on 2026-10-24.
Branched from `main` at `45864c4` (Joaquin's ArcFace build). The speech side is branch `muse`;
read its `CONVERSATION-AID.md` too. This file covers the face side and the seams between them.

## What changed from main

| area | change |
|---|---|
| Detector | **SCRFD-500M** (InsightFace) via Core ML replaces Vision's face detector. `App/FaceDetector.swift`. Fixed 512x896 input = a glasses frame with 8 px padding, no downscaling. Returns 5 keypoints, used directly for the ArcFace alignment. Falls back to Vision if the model is missing or `useSCRFD` = 0. |
| Stream | 2 fps, medium (504x896) by default (was 7 fps low). 0.9 vs 1.6 Mpx/s over the radio, faces ~1.4x bigger. Knobs `streamFps`, `streamRes`. |
| Which face | Each face gets an **attention** score (size x closeness to the middle of the view x facing the camera) and a **quality** score (size x frontal). Live frames embed the most-attended faces first; faces under `minFacePx` (32) are ignored (the crowd behind your partner). |
| Tracker | Looks are weighted by quality when fused (`FaceTracks.swift`); `maxAge` 3 s and `minOverlap` 0.15 for 2 fps; tracks carry `attention`. |
| Show policy | Only the face you're looking at may take the lens (attention >= `focusShare` x the frame's max). One clear look is enough for a strong match (score >= `strongScore` 0.55), else `minEvidence` (1.6). A card holds the lens for `cardHolds` (3 s, was 20) before someone else may replace it. |
| Conversation memory | Once someone has been on the lens they stay quiet while they keep being seen; only after `absentFor` (180 s) out of view are they announced again. So a three-person conversation names each person once. |
| Identify press | Feeds its frames into the tracker and uses the fused evidence for the face you're looking at, instead of judging one frame. Fixed "recognises Avi once, then never again". |
| Gallery | `galleryVersion` 5: references re-embed through SCRFD on first launch. |

## Seams for the speech merge

- **`Glasses.facing: String?`**: person id of the known face you're looking at right now, nil when
  nobody known is in view. Observable, plus `Glasses.onFacing` callback on change. This is the
  natural "who is THEM" for the aid: when the other speaker talks, `facing` is almost always them.
  Feed it into the aid's them-profile instead of (or before) the model guessing.
- **`Glasses.present: [String]`**: everyone confidently seen in the last 10 s. For group
  conversations: candidates for who a diarized speaker label could be.
- **Lens ownership**: on this branch a conversation answer (`Glasses.answer`, `showAnswer`) still
  owns the lens and blocks auto cards (`mayShow`), but **scanning keeps running**, so `facing` and
  `present` stay live during answers. `muse` wants to replace `AnswerCard`/`showAnswer` with its
  `LensView`, and says an identification should win over an aid card while it's fresh. That is the
  one policy decision for the merge: change `mayShow`'s `answer == nil` guard and `renderLens()`
  accordingly.
- Conversation memory means auto cards are rare once everyone is introduced, which leaves the lens
  free for the aid most of the time.

## Models (licence: non-commercial research only, so NOT in git)

`App/*.mlmodel` and `App/*.mlpackage` are gitignored. Without them the app still builds and runs,
falling back to Vision (detector) and Vision feature print (embedder), and logs which it used
(`detector` / `embedder` events in `Documents/speed.jsonl`).

- Toby's laptop: `~/Developer/calhacks-models/` holds `SCRFD_500M.mlpackage`,
  `MobileFaceNet_w600k.mlmodel` and the source ONNX files. Copy both models into `App/` before building.
- Build Mac: `tools/qm-deploy.sh` copies both from `~/calhacks/models/` if present.
- Rebuild from scratch: download InsightFace `buffalo_s.zip` (v0.7 release), then
  `tools/face-models/convert_scrfd.py det_500m.onnx SCRFD_500M.mlpackage <probe.jpg>` and
  `tools/face-models/convert_mobilefacenet.py w600k_mbf.onnx MobileFaceNet_w600k.mlmodel`
  (Python 3.11 with coremltools, torch, onnx2torch, onnxruntime, opencv). Both print a parity check.

## Measured (`sh tools/face-bench/run.sh`)

The 43 references shrunk to 24-96 px faces in a 504x896 frame, clean and motion-blurred.

| | Vision | SCRFD-500M |
|---|---|---|
| faces found, 24 px blurred / 32 px blurred | 0% / 77% | 93% / 100% |
| right person named at conversation distance (48-96 px) | 99-100% | 100% |
| wrong names, all 430 frames | 0 | 0 |
| detect time, Mac | 5.8 ms | 7.2 ms |

The gain is in finding hard faces (small, blurred, turned); on clear faces both match equally well
(same median lead over the runner-up, 0.67). YuNet (MIT licence) matched SCRFD on detection and is
the swap if the licence ever matters.

## Tuning without a rebuild

All of these are keys in `Documents/tuning.json` (see `App/Tuning.swift`, `tools/qm-tune.sh`):
`useSCRFD`, `detScore` (0.5), `minFacePx` (32), `focusShare` (0.7), `strongScore` (0.55),
`minEvidence` (1.6), `cardHolds` (3), `absentFor` (180), `streamFps` (2), `streamRes` (medium),
plus the existing `minScore`/`minGap`.

## Not yet verified

- On the glasses since SCRFD went in: detection rate, on-device detect time, battery at 2 fps.
- Conversation memory in a real group (only one person was available to test with).
- `speed.jsonl` now logs `detector`, `attention` and `inFrame` on each auto identify, and
  `fused`/`looks` on a press: pull it with
  `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier com.tobiasvonkoch.calhacks13 --source Documents/speed.jsonl --destination speed.jsonl`.
- Meta AI asked for permission again after each install on Toby's phone; cause unknown (possibly
  two dev-mode apps both using MetaAppID "0").
