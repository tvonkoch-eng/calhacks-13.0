"""Stage 3: screen photos/ for usable faces with OpenCV YuNet.

    python facecheck.py

OK     exactly one confident face, big enough to enrol
SMALL  one face but under 80 px or under 12% of the image width
MULTI  more than one confident face (group shot: can't tell which is them)
NONE   no face found (logo, cartoon, back of head, sunglasses + hat...)

Writes out/facecheck.csv and out/flagged_sheet.jpg (contact sheet of everything that isn't OK).
"""
import csv
import json
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).parent
PHOTOS, OUT = HERE / "photos", HERE / "out"
SCORE_MIN, SECOND_MIN, MIN_PX, MIN_FRAC = 0.8, 0.6, 80, 0.12


def main() -> None:
    names = {p["id"]: p["name"] for p in json.loads((OUT / "people_new.json").read_text(encoding="utf-8"))}
    det = cv2.FaceDetectorYN.create(str(HERE / "models/yunet.onnx"), "", (320, 320), score_threshold=0.5)
    rows, flagged = [], []
    for path in sorted(PHOTOS.glob("*_01.jpg")):
        pid = path.name.removesuffix("_01.jpg")
        img = cv2.imread(str(path))
        if img is None:
            rows.append((pid, names.get(pid, ""), "NONE", 0, 0, 0))
            flagged.append((pid, "NONE", path))
            continue
        h, w = img.shape[:2]
        det.setInputSize((w, h))
        _, faces = det.detect(img)
        faces = [] if faces is None else sorted(faces, key=lambda f: f[2] * f[3], reverse=True)
        if not faces or faces[0][-1] < SCORE_MIN:
            verdict, fw, score = "NONE", 0, 0.0
        else:
            fw, score = int(faces[0][2]), float(faces[0][-1])
            second = len(faces) > 1 and faces[1][-1] >= SECOND_MIN and faces[1][2] >= 0.5 * faces[0][2]
            verdict = "MULTI" if second else ("SMALL" if fw < MIN_PX or fw / w < MIN_FRAC else "OK")
        rows.append((pid, names.get(pid, ""), verdict, len(faces), fw, round(score, 2)))
        if verdict != "OK":
            flagged.append((pid, verdict, path))

    with open(OUT / "facecheck.csv", "w", encoding="utf-8", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["id", "name", "verdict", "faces", "face_px", "score"])
        wr.writerows(rows)

    counts = {}
    for r in rows:
        counts[r[2]] = counts.get(r[2], 0) + 1
    print(counts)
    for v in ("NONE", "MULTI", "SMALL"):
        print(v, [names.get(p, p) for p, vv, _ in flagged if vv == v])

    # Contact sheet of flagged photos so they can be eyeballed.
    tile, cols = 200, 6
    cells = []
    for pid, verdict, path in flagged:
        img = cv2.imread(str(path))
        img = np.zeros((tile, tile, 3), np.uint8) if img is None else cv2.resize(img, (tile, tile))
        cv2.rectangle(img, (0, 0), (tile, 34), (0, 0, 0), -1)
        cv2.putText(img, f"{verdict} {names.get(pid, pid)[:18]}", (4, 22), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (255, 255, 255), 1, cv2.LINE_AA)
        cells.append(img)
    if cells:
        while len(cells) % cols:
            cells.append(np.zeros((tile, tile, 3), np.uint8))
        sheet = np.vstack([np.hstack(cells[i:i + cols]) for i in range(0, len(cells), cols)])
        cv2.imwrite(str(OUT / "flagged_sheet.jpg"), sheet)
        print("sheet:", sheet.shape)


if __name__ == "__main__":
    main()
