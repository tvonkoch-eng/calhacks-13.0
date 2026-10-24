# Cal Hacks 13.0: conversation assistant

First draft: on-device face recognition for the team (Toby, Joaquin, Mirabelle, Avi). Everyone in it has given consent.

- **People**: a minimal CRM of teammates (name, role, facts from `App/people.json`).
- **Add face photos**: on a person, tap the shutter (exactly one face in frame) or import from Photos. 5 to 10 angles each.
- **Seed photos**: drop `App/Faces/<id>.jpg` (`joaquin`, `mirabelle`, `avi`, `toby`). On first launch each one becomes that person's avatar and first face sample.
- **Glasses (home screen)**: press to identify. Tap Identify on the phone, the Identify button on the lens, or the glasses capture button (needs Inputs enabled for the app in Wearables Developer Center). It matches the newest glasses frame and falls back to a full photo. Wrong match or unknown face: "Save as…" adds that face to a person.

Pipeline: Vision face detection → square crop → Vision feature print → cosine vs. each person's best sample, plus a runner-up margin. No server. Face samples stay on the phone.

```
xcodegen && open CalHacks.xcodeproj   # run on your iPhone
```
