# Cal Hacks 13.0: conversation assistant

First draft: on-device face recognition for the team (Toby, Joaquin, Mirabell, Avi). Everyone in it has given consent.

- **People**: a minimal CRM of teammates (name, role, facts from `App/people.json`).
- **Add face photos**: on a person, tap the shutter (exactly one face in frame) or import from Photos. 5 to 10 angles each.
- **Scan**: live camera. Each face gets matched and shows a card. *Strictness* slider = cosine threshold.

Pipeline: Vision face detection → square crop → Vision feature print → cosine vs. each person's best sample, plus a runner-up margin. No dependencies, no server. Face samples stay on the phone (Documents/gallery.json).

```
xcodegen && open CalHacks.xcodeproj
```
