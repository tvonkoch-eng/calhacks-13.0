# LinkedIn roster enrichment

Turns a CSV of **consented** sign-ups (name + LinkedIn URL) into roster entries and reference photos
in the format the app uses (`App/people.json`, `App/References/<id>_01.jpg`). Nothing here is
committed except code: the CSV, raw scrapes, photos, outputs and the token are all gitignored.

| Stage | Script | What it does |
|---|---|---|
| 1 | `fetch.py` | Apify `harvestapi/linkedin-profile-scraper` (profile, education, experience, photo; ~$0.004 each) and `harvestapi/linkedin-profile-posts` (recent posts). No LinkedIn login. Raw output cached in `raw/`; reruns only fetch new people. |
| 2 | `build.py` | Maps to the roster shape: `tie`, 2-3 `highlights`, `personal`, `source`, contact fields. Downloads the profile photo right away (the URLs expire). Also writes `out/enrichment.json` (full education/experience/posts). |
| 3 | `facecheck.py` | Screens photos with OpenCV YuNet: OK / SMALL / MULTI / NONE, plus a contact sheet of everything flagged to check by eye. |
| 4 | `package.py` | Writes `out/import/`: roster entries and photos for usable people, and `needs_selfie.txt`. |

## Run

```bash
pip install -r requirements.txt
# put people.csv here (columns: name, linkedin_url, school, focus, description, summary, other_links, email)
# put the Apify token in .env:  APIFY_TOKEN=...
# download models/yunet.onnx from opencv_zoo (face_detection_yunet_2023mar.onnx)
python fetch.py --limit 2     # test on two people first
python fetch.py
python build.py
python facecheck.py           # then look at out/flagged_sheet.jpg
python package.py
```

`overrides.json` (local, optional) records the calls made by eye: `{"force_ok": [ids], "unusable": [ids]}`.

## Before using the output

- **Only enrol people who agreed** to LinkedIn data collection and face recognition for the demo.
- **Do not commit `out/` or `photos/`** to this repo: it is public, and `tools/qm-publish.sh` only
  redacts four fields of `people.json`, not the reference photos.
- Append `out/import/people_new.json` to the **hub's private roster**, not the public `App/people.json`
  (which has the teammates' `tie`/`highlights`/`personal`/`source` stripped).
- Cost for 218 people was about $2.
