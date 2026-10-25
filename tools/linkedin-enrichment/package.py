"""Stage 4: package an import folder for the app. Touches nothing outside out/import/.

    python package.py

out/import/people_new.json      roster entries for everyone with a usable photo
out/import/References/          <id>_01.jpg for each of them (App/References naming)
out/import/needs_selfie.txt     people who can't be recognised yet, and why
"""
import csv
import json
import shutil
from pathlib import Path

HERE = Path(__file__).parent
OUT, IMP = HERE / "out", HERE / "out" / "import"
# Per-person calls made by eye after looking at out/flagged_sheet.jpg. Kept in a local, gitignored
# overrides.json so no participant names live in the code:
#   {"force_ok": ["<id>", ...],   detector missed it but the photo is a clear face
#    "unusable": ["<id>", ...]}   logo, back of head, sunglasses + cap...
_ov = HERE / "overrides.json"
_ov = json.loads(_ov.read_text(encoding="utf-8")) if _ov.exists() else {}
FORCE_OK, UNUSABLE = set(_ov.get("force_ok", [])), set(_ov.get("unusable", []))


def main() -> None:
    people = json.loads((OUT / "people_new.json").read_text(encoding="utf-8"))
    verdict = {r["id"]: r["verdict"] for r in csv.DictReader(open(OUT / "facecheck.csv", encoding="utf-8"))}
    shutil.rmtree(IMP, ignore_errors=True)
    (IMP / "References").mkdir(parents=True)

    ready, weak, need = [], [], []
    for p in people:
        pid, v = p["id"], verdict.get(p["id"])
        if v is None:
            need.append((p["name"], "no LinkedIn photo"))
        elif pid in UNUSABLE or (v == "NONE" and pid not in FORCE_OK):
            need.append((p["name"], "photo isn't a usable face"))
        else:
            ready.append(p)
            shutil.copy(HERE / "photos" / f"{pid}_01.jpg", IMP / "References" / f"{pid}_01.jpg")
            if v in ("SMALL", "MULTI") and pid not in FORCE_OK:
                weak.append(p["name"])

    (IMP / "people_new.json").write_text(json.dumps(ready, ensure_ascii=False, indent=2), encoding="utf-8")
    lines = [f"NEED A SELFIE ({len(need)})"] + [f"- {n}: {why}" for n, why in need]
    lines += ["", f"WEAK PHOTO, selfie would help ({len(weak)})"] + [f"- {n}" for n in weak]
    (IMP / "needs_selfie.txt").write_text("\n".join(lines), encoding="utf-8")
    print(f"ready to import: {len(ready)} | weak photo: {len(weak)} | need selfie: {len(need)}")
    print("ids clash with existing roster:", sorted({p['id'] for p in ready} & {"joaquin", "mirabelle", "avi", "toby"}))


if __name__ == "__main__":
    main()
