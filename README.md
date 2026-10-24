# Cal Hacks 13.0: conversation assistant

First draft: on-device face recognition for the team (Toby, Joaquin, Mirabelle, Avi). Everyone in it has given consent.

- **People**: a minimal CRM of teammates (name, role, facts from `App/people.json`).
- **Add face photos**: on a person, tap the shutter (exactly one face in frame) or import from Photos. 5 to 10 angles each.
- **Seed photos**: drop `App/Faces/<id>.jpg` (`joaquin`, `mirabelle`, `avi`, `toby`). On first launch each one becomes that person's avatar and first face sample.
- **Scan**: Phone or Glasses source. Each face gets matched and shows a card. *Strictness* = cosine threshold.
- **Glasses** (Meta DAT SDK 1.0.1): streams the glasses camera at 504x896 / 7 fps. On Ray-Ban Display, the matched person's card goes on the lens. Needs Developer Mode in Meta AI (Settings > your glasses > Developer Mode). Tap Connect, approve in Meta AI, come back, and tap Connect again.

Pipeline: Vision face detection → square crop → Vision feature print → cosine vs. each person's best sample, plus a runner-up margin. No server. Face samples stay on the phone.

```
xcodegen && open CalHacks.xcodeproj   # run on your iPhone
```
