# Handoff: face recognition on Meta Ray-Ban Display (Cal Hacks 13.0)

Read this first, then `CONTEXT.md` (product intent from the team's notes).

**Goal right now:** looking at a teammate and pinching Identify on the glasses should put their card on
the lens fast, every time, with no lag, missed pinches, band drops or dead second scans. If the
packed hackathon room's radio environment is the limit, prove it with logs and design around it.

## State (2026-10-23, ~9 PM)

- Branch **`crm-redesign`** is the working branch. It contains everything: `main` + the
  conversation-assist patch + CRM redesign + lens HUD + Lens Lab + tonight's glasses fixes.
- Installed on Toby's iPhone 17 Pro (UDID `00008150-000E55140204C01C`), team `VBT92TS7FT`,
  bundle `com.tobiasvonkoch.calhacks13`. Glasses: Meta Ray-Ban Display + Neural Band, Developer Mode.
- Latest commit **`d4ae761` has NOT been verified on the glasses yet.** Start by testing it.

## Taking over on your own Mac (Joaquin)

Building, installing and pulling logs all happen from the Mac that the iPhone is plugged into, and
the iPhone has to be the one paired with the glasses in Meta AI. One-time setup:

1. **Xcode 26.4+** (from the App Store), opened once so it installs its components. Then
   `brew install xcodegen`.
2. `git clone https://github.com/tvonkoch-eng/calhacks-13.0 && cd calhacks-13.0 && git checkout crm-redesign`
3. **Signing:** in `project.yml` set `DEVELOPMENT_TEAM` to your own Apple team ID and change
   `PRODUCT_BUNDLE_IDENTIFIER` to something unique (for example `com.jdelpego.calhacks13`), or get
   added to team `VBT92TS7FT`. Do the same in `LensLab/project.yml` if you use Lens Lab.
4. `cp Secrets.example.xcconfig Secrets.xcconfig` (face ID needs no key; only conversation assist does).
5. **Phone:** plug in and unlock it, trust the Mac, and turn on Developer Mode
   (Settings > Privacy & Security). Find the UDID with `xcrun devicectl list devices`.
6. **Glasses:** in the Meta AI app on that phone, turn on Developer Mode
   (Settings > your glasses > Developer Mode). The app asks you to approve it in Meta AI on first launch.
7. Build, install and launch with the commands below. If you changed the bundle ID, use the new one
   in the `launch` and log commands too.

Face photos for the four of us are bundled (`App/References`, `App/Faces`), so recognition works on a
fresh install. Saved history and the speed log live on the phone and reset when the app is deleted.

## Build and run

```sh
cp Secrets.example.xcconfig Secrets.xcconfig   # needed by project.yml; add a Groq key only for conversation assist
xcodegen
xcodebuild -project CalHacks.xcodeproj -scheme CalHacks -destination 'generic/platform=iOS' \
  -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device <UDID> build/Build/Products/Debug-iphoneos/CalHacks.app
xcrun devicectl device process launch --terminate-existing --device <UDID> com.tobiasvonkoch.calhacks13
```

Never commit `Secrets.xcconfig` (gitignored on purpose; it once held a live Groq key).
Launch fails with error 10002 / "Locked" when the phone is locked; the install still succeeded.

## The feedback loop: speed log

Every identify, and every connection/lens/confirm event, appends one JSON line to
`Documents/speed.jsonl` on the phone (also os_log subsystem `com.tobiasvonkoch.calhacks13`, category `speed`).

```sh
xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer \
  --domain-identifier com.tobiasvonkoch.calhacks13 --source Documents/speed.jsonl --destination ./speed.jsonl
```

(The phone must be unlocked or the copy fails with ContainerLookupErrorDomain -1. `tools/speed.sh`
summarizes the older per-scan fields.)

- Scan lines: `source` (phone/lens/glasses), `frames`, `frameMs` (stream start to first frame),
  `captureMs`, `faces`, `detectMs`, `embedMs`, `matchMs`, `toResultMs` (phone shows answer),
  `lensMs` (lens write), `totalMs`, `person`, `score`, `runnerUp`.
- Event lines: `connect` stages, `connected`, `session` state changes, `reconnect`, `skipped`
  (press ignored + reason), `confirmAsk` / `confirmExpired`, `lensSlow` (>1 s) / `lensError`,
  `frameTimeout`, `streamError`, `connectError`.

## No-hardware loop

- **Phone-sim rig (DEBUG):** the glasses pill in the header has a "Run on" section — *Real glasses*
  or *This phone (simulated)*. Switching drops the session, swaps the kit under it and reconnects,
  so no rebuild and no relaunch. The choice is stored in `UserDefaults` (`MockGlasses`) and survives
  a plain icon tap; `MOCK_GLASSES=1` / `=0` still overrides it when Xcode or devicectl sets it.
  In phone-sim mode MockDeviceKit pairs simulated Ray-Ban Display glasses, streams the iPhone's own
  back camera as the glasses feed (`MOCK_CAMERA=front` for the selfie camera) and mirrors the real
  lens into the LensPanel at the top of the app.
- **LensPanel:** always visible in DEBUG, labelled with which rig is live. In phone-sim mode the
  black square is MockDeviceKit rendering the same `FlexBox` the glasses would get. With real
  glasses the SDK offers no preview view, so the panel says where the card actually is instead of
  drawing a fake one.
  Extras: `PREVIEW_PERSON=avi` (show a match), `PREVIEW_CONFIRM=1` ("Are you sure?"),
  `PREVIEW_SEEN="joaquin:7200,mirabelle:960"` (seconds ago), `PREVIEW_OPEN=avi` (open profile).
  With `xcrun simctl launch`, prefix each with `SIMCTL_CHILD_`. Xcode 27 has no Simulator.app,
  so screenshot with `xcrun simctl io <sim> screenshot`.
- **Lens Lab** (`LensLab/`, own xcodegen project): renders a designed 7-screen lens flow plus a
  component gallery through Meta's real Display renderer. `LENS_PAGE=<n>` picks a page.
- Vision face detection returns nothing in the simulator; recognition itself can only be tested on
  device, or on macOS with the same Vision code (a leave-one-out script got 17/17 on the team photos).

## How it works

| File | What |
|---|---|
| `App/Face.swift` | Vision face rect → square crop → `VNGenerateImageFeaturePrintRequest` (normalized) → cosine. `scan(limit: 1)` embeds only the largest face. |
| `App/Store.swift` | People (`people.json`), face gallery (`Documents/gallery.json`), bundled `App/References/<id>_NN.jpg` loaded once, headshot avatars (`App/Faces`), encounters, notes. **No threshold:** the closest teammate always wins (Toby's call, tiny consenting dataset). |
| `App/Glasses.swift` | DAT SDK session, frame capture, lens HUD, confirm, Inputs, reconnect, speed log. |
| `App/LensCards.swift` | Lens UI (Display DSL): idle = floating counter + focused Identify; matched = card with photo, name, role, 3 detail rows, then the same bottom row. |
| `App/App.swift` | Phone CRM: People home, TALKING NOW card, person record (stats, notes, activity). |
| `App/Listen.swift`, `Assistant.swift`, `Question.swift`, `Answer.swift` | Conversation assist (phone mic → question → Groq answer on the lens). Separate workstream. |

Identify flow: press (phone button, lens button via band pinch, or capture button) → start camera
stream (`.medium`, 7 fps) → first usable frame (up to 3 tries) → stop stream → detect + embed + match →
record encounter → write lens. From the glasses with someone already showing, the first press shows
"Are you sure?" and a second press within 2 s (timed from when it is visible) re-scans.

## What tonight's logs proved

1. **`camera.photo` capture fails on every scan** (0 bytes in ~20 ms), so the app used the stream
   fallback. The PhotoError was never logged. Removed the photo path. Worth retrying with the error
   logged: it may need Camera Capture approval in the Wearables Developer Center (it is experimental).
2. **Stream cold start ≈ 1.9–2.2 s** per scan. This is most of the latency now.
3. **Keeping the stream warm was harmful.** Lens writes went to 2.8 s and then failed after ~5 s,
   the glasses ended the session, and the Neural Band disconnected. Video, display and band share the
   glasses' radio. The stream is now stopped before every lens write.
4. **The confirm double-press broke under lag.** "Are you sure?" reached the lens after its 2 s window
   had closed, so the second pinch only re-asked and scans never ran. Fixed in `d4ae761` (window
   starts after the lens shows it). Verify on device.
5. **`InputsConfiguration()` defaults include `.neuralBand` and `.captouch`** and swallow the band's
   pinch (haptic, no click). Now limited to `[.captureButton, .actionButton]`. The capture button only
   reaches the app if **Inputs** is enabled for the app in the Wearables Developer Center.
6. **Connection fixes:** check permissions only after the glasses are found (else
   `PermissionError.noDevice`, which printed as a garbage rawValue). Use `SpecificDeviceSelector`
   for the found device. Wait for `linkState == .connected && compatibility == .compatible`. Get
   `session.stateStream()` **before** `start()` (subscribing inside a Task raced and hung on
   "Starting session…").
7. **Matching margins are thin:** Avi scored 0.67–0.79 vs runner-up 0.61–0.69 (Vision feature
   print is a generic image embedding, not a face model).
8. **Environment:** in the packed hall the glasses lagged even with CalHacks not running, so part of
   the problem is RF congestion (2.4 GHz BT/Wi-Fi) or the glasses themselves (restart, firmware, battery).

## Open problems, in priority order

1. **Verify `d4ae761` on the glasses** and pull the log: repeat scans, band stability, lens write times.
2. **Separate the room from the app:** same test in a quiet hallway vs the hall, and the glasses' own
   UI with the app closed. Write down the numbers.
3. **Cut capture latency (~2 s cold start):** get `camera.photo` working (log its PhotoError and check
   Developer Center approval), compare `.low` vs `.medium` resolution, `stream.capturePhoto` while
   streaming, and a 2 fps idle stream (measure what it does to band stability before keeping it).
4. **Lens writes:** keep payloads tiny (the avatar is 96 px; try without it), avoid writes during capture.
5. **Accuracy:** replace the feature print with a real face embedding (MobileFaceNet / ArcFace in
   Core ML), or at least enroll real glasses frames per person via "Not X?". A 5-10 photo gallery per
   person from the glasses camera would help a lot.
6. **Demo fallback:** phone Identify uses the same glasses camera and lens; keep it working.

## Constraints

- Only consenting people: Toby, Joaquin Del Pego, Mirabelle Brown, Avi Shah.
- Meta's developer terms (checked 2026-10-19) prohibit face identification on the glasses without
  Meta's prior approval. This matters for the Meta prize submission.
- Lens DSL limits: bottom-anchored cards, text heading/body/meta x primary/secondary only, images
  either `.icon` (tiny) or `.fill` (whole lens), non-primary buttons in a ButtonGroup render
  icon-only. There is no plain briefcase icon (`crossBriefcase` is a first-aid kit).
- Toby wants changes installed on his phone, not screenshots, and a clean consumer UI (no scores or
  debug text in the UI; put diagnostics in the speed log).
