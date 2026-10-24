# Project context

AR glasses for networking events: recognize someone, show who they are, help during the conversation.
Cleaned up from the team's Granola notes (Cal Hacks 13.0).

## Core flow

- **Manual identification**: press to identify, not always-on. Automatic ID was ruled out because of the battery cost.
- On identification, show **preloaded** background info about the person:
  - headshot, name
  - current role / employer
  - school
  - shared interests
- **Generic vs. personalized** (still open). Generic means everyone sees the same card. Personalized means the card shows what overlaps with you: show school only if it's shared, and surface a shared hobby. The idea is a simple decision tree (same school → show school, shared hobby → show hobby).
  - Leaning: **ship generic first**, add personalization if there's time.

## Three product elements

1. **Preloaded info display** when you look at someone.
2. **Triage**: who should I talk to. Ranking or scoring people is deprioritized because a "social cred score over someone's head" feels off. Instead, let the user ask the agent ("who here works at Google?").
3. **Real-time in-conversation assistance** (audio + occasional photos). This is the most useful feature long term.

## Demo strategy

- **Glasses only.** Judges won't engage with a second UI, so a web app or dashboard is friction.
- The pitch can describe the broader vision (CRM, connection tracking). The demo stays on the glasses.
- A companion app (web or mobile) is useful for the CRM, but it's secondary.

## Build priorities

1. Headshot + name, preloaded. *(v1 in this repo: on-device face match, CRM of the team, lens card on Display glasses)*
2. Background info from LinkedIn scraping (Apify).
3. Real-time conversation assist. *(v1 in this repo: phone mic → question detection → answer on the lens, speculated mid-sentence. See "Conversation assist" in the README.)*

## Data for the demo

- Small **sign-up form**: each person gives a photo + LinkedIn and explicit consent.
- Target ~100 people from the team's network.
- Only consenting people get enrolled. Today that's the team: Toby, Joaquin, Mirabelle, Avi.

## Open questions / next steps

- [ ] Decide generic vs. personalized card (tailored to the user's stated goals?).
- [ ] Build the consent sign-up form (photo + LinkedIn).
- [ ] Apify LinkedIn scrape → profile JSON in the app's format (`App/people.json`: name, role, facts).
- [x] Press to identify on the glasses (phone button, lens button, capture button via Inputs).
- [x] Spot a factual question in live speech and put the answer on the lens, answering speculatively from the partial transcript so the latency lands inside the question.
- [ ] Mic on the glasses instead of the phone (MWDAT audio) — phone mic first because it is one less SDK surface to fight during the hack.
- [ ] Speaker attribution: right now it answers any question it hears, including the wearer's own.
- [ ] Fold the person being identified into the answer context, so "where does she work" resolves.
- [ ] Note: Meta's developer terms (checked Oct 19) prohibit face identification on the glasses without Meta's prior approval. Confirm how this affects the Meta prize demo.
