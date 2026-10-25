"""Stage 2: turn raw Apify output into the app's roster format and download profile photos.

    python build.py

Reads  people.csv, raw/profiles.json, raw/posts.json
Writes out/people_new.json   roster entries in the shape of App/people.json
       out/enrichment.json   education + experience history + recent posts per person id
       out/report.txt        coverage and the people who need a look
       photos/<id>_01.jpg    profile photo (LinkedIn's photo URLs expire, so this runs right after fetch)
"""
import csv
import json
import re
import unicodedata
from datetime import date
from pathlib import Path
from urllib.parse import unquote

import requests

HERE = Path(__file__).parent
OUT, PHOTOS = HERE / "out", HERE / "photos"
RESERVED_IDS = {"joaquin", "mirabelle", "avi", "toby"}  # already in the app's roster


def slug(text: str) -> str:
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def handle(url: str) -> str:
    m = re.search(r"linkedin\.com/in/([^/?#]+)", url or "")
    return unquote(m.group(1)).lower().rstrip("/") if m else ""


def first_sentences(text: str, n: int = 3) -> list[str]:
    parts = [p.strip(" .") for p in re.split(r"(?<=[.;])\s+", text or "") if p.strip(" .")]
    return parts[:n]


WIN = re.compile(r"(?<![a-z])(won|wins?|winner|1st|2nd|3rd|finalist|prize|champion|best|top \d+|placed|podium|award)(?![a-z])", re.I)


def standout(summary: str, description: str) -> str | None:
    """One achievement line from the sign-up notes, if there is one. Skips logistics like
    'looking for a team' that don't belong on a lens card."""
    for part in first_sentences(f"{summary}. {description}", 6):
        part = part.rstrip("; ")
        if WIN.search(part) and 12 <= len(part) <= 58:
            return part
    return None


def short(text: str | None, limit: int = 58) -> str | None:
    """Lens lines are one short row: drop 'X - long name' tails, collapse spaces, cut with an ellipsis."""
    if not text:
        return None
    text = re.sub(r"\s+", " ", text.split(" - ")[0]).strip()
    return text if len(text) <= limit else text[: limit - 1].rstrip(" ,;·@") + "…"


def other_links(raw: str) -> dict:
    out = {}
    for part in re.split(r"[;\s]+", raw or ""):
        part = part.strip()
        if "instagram.com/" in part:
            out["instagram"] = part.rstrip("/").split("/")[-1].lstrip("@")
        elif part.startswith("Instagram:"):
            out["instagram"] = part.split("@")[-1]
        elif part.startswith("http") and not any(s in part for s in ("github.com", "devpost.com", "x.com", "twitter.com")):
            out.setdefault("website", re.sub(r"^https?://(www\.)?", "", part).rstrip("/"))
    return out


def by_name(profiles: list[dict], csv_name: str, taken: set[str], csv_handle: str = "") -> dict | None:
    """A LinkedIn handle that was renamed redirects, so the URL in the CSV no longer matches
    publicIdentifier. Fall back to a unique first+last name match."""
    want = set(slug(csv_name).split("-")) | set(slug(csv_handle).split("-"))
    hits = [
        p for p in profiles
        if p.get("firstName") and p.get("publicIdentifier") not in taken
        and slug(p["firstName"]).split("-")[0] in want and slug(p.get("lastName") or "").split("-")[0] in want
    ]
    return hits[0] if len(hits) == 1 else None


def best_photo_url(profile: dict) -> str | None:
    pic = profile.get("profilePicture") or {}
    sizes = sorted(pic.get("sizes") or [], key=lambda s: s.get("width", 0), reverse=True)
    return (sizes[0]["url"] if sizes else None) or pic.get("url") or profile.get("photo")


def main() -> None:
    OUT.mkdir(exist_ok=True)
    PHOTOS.mkdir(exist_ok=True)
    rows = [r for r in csv.DictReader(open(HERE / "people.csv", encoding="utf-8-sig", newline="")) if r["linkedin_url"].strip()]
    profiles = json.loads((HERE / "raw/profiles.json").read_text(encoding="utf-8"))
    seen_ids: set[str] = set()
    profiles = [p for p in profiles if not (p.get("publicIdentifier") in seen_ids or seen_ids.add(p.get("publicIdentifier")))]
    posts = json.loads((HERE / "raw/posts.json").read_text(encoding="utf-8"))

    by_handle = {handle(p.get("linkedinUrl", "")) or (p.get("publicIdentifier") or "").lower(): p for p in profiles}
    for p in profiles:
        by_handle.setdefault((p.get("publicIdentifier") or "").lower(), p)
    posts_by = {}
    for post in posts:
        key = ((post.get("author") or {}).get("publicIdentifier") or "").lower()
        posts_by.setdefault(key, []).append(post)

    used_profiles: set[str] = set()
    people, enrich, used_ids = [], {}, set(RESERVED_IDS)
    no_profile, no_photo, photo_fail = [], [], []
    today = date.today().isoformat()

    for row in rows:
        h = handle(row["linkedin_url"])
        prof = by_handle.get(h) or by_name(profiles, row["name"], used_profiles, h)
        if not prof or not (prof.get("firstName") or prof.get("lastName")):
            no_profile.append(row["name"])
            continue

        used_profiles.add(prof.get("publicIdentifier"))
        h = (prof.get("publicIdentifier") or h).lower()
        name = row["name"].strip()
        base = slug(f"{prof.get('firstName', '')} {prof.get('lastName', '')}") or slug(name)
        pid, i = base, 2
        while pid in used_ids:
            pid, i = f"{base}-{i}", i + 1
        used_ids.add(pid)

        edu = prof.get("education") or []
        exp = prof.get("experience") or []
        cur = (prof.get("currentPosition") or [{}])[0]
        loc = (prof.get("location") or {}).get("parsed") or {}

        school = None
        if edu:
            e = edu[0]
            degree = ", ".join(x for x in (e.get("degree"), e.get("fieldOfStudy")) if x)
            school = " · ".join(x for x in (e.get("schoolName"), degree) if x)
        school = school or row["school"] or None
        work = " @ ".join(x for x in (cur.get("position"), cur.get("companyName")) if x) or row["description"] or None
        place = ", ".join(x for x in (loc.get("city"), loc.get("state") if loc.get("countryCode") == "US" else loc.get("country")) if x)

        links = other_links(row["other_links"])
        tags = [t for t in (
            (edu[0].get("schoolName") if edu else None), cur.get("companyName"), loc.get("city"), "Cal Hacks",
        ) if t]
        school_line = None
        if edu:
            e0 = edu[0]
            school_line = " · ".join(x for x in (e0.get("schoolName"), e0.get("fieldOfStudy")) if x)
        # Same shape as the four teammates' private entries: a tie, 2-3 highlights, a personal line.
        at_ucsb = bool(re.search(r"santa barbara|ucsb", f"{school or ''} {row['school']}", re.I))
        tie = "Also at UCSB · Cal Hacks 13" if at_ucsb else "Also at Cal Hacks 13"
        win = standout(row["summary"], row["description"])
        highlights = [x for x in (short(work), short(school_line or school), short(win)) if x][:3]
        person = {
            "id": pid,
            "name": name,
            "role": prof.get("headline") or row["description"] or "",
            "school": school,
            "work": work,
            "from": place or None,
            "interests": row["focus"] or None,
            "tags": tags,
            "tie": tie,
            "highlights": highlights,
            "personal": f"From {place}" if place else None,
            "source": f"LinkedIn · {today}",
            "linkedin": h,
            "website": links.get("website") or (prof.get("websites") or [None])[0],
            "instagram": links.get("instagram"),
            "email": row["email"] or None,
        }
        people.append({k: v for k, v in person.items() if v not in (None, "", [])})

        enrich[pid] = {
            "headline": prof.get("headline"),
            "about": prof.get("about"),
            "education": [
                {k: e.get(k) for k in ("schoolName", "degree", "fieldOfStudy", "period")} for e in edu
            ],
            "experience": [
                {
                    "position": x.get("position"), "company": x.get("companyName"),
                    "duration": x.get("duration"), "start": (x.get("startDate") or {}).get("text"),
                    "end": (x.get("endDate") or {}).get("text"), "description": x.get("description"),
                }
                for x in exp
            ],
            "topSkills": prof.get("topSkills"),
            "recentPosts": [
                {
                    "date": ((p.get("postedAt") or {}).get("date") or "")[:10],
                    "text": (p.get("content") or "")[:500],
                    "likes": (p.get("engagement") or {}).get("likes"),
                    "url": p.get("linkedinUrl"),
                }
                for p in sorted(posts_by.get(h, []), key=lambda p: (p.get("postedAt") or {}).get("timestamp", 0), reverse=True)
            ],
        }

        url = best_photo_url(prof)
        if not url:
            no_photo.append(name)
            continue
        try:
            r = requests.get(url, timeout=30)
            r.raise_for_status()
            (PHOTOS / f"{pid}_01.jpg").write_bytes(r.content)
        except Exception as exc:  # expired/blocked URL: report, don't stop
            photo_fail.append(f"{name} ({exc.__class__.__name__})")

    (OUT / "people_new.json").write_text(json.dumps(people, ensure_ascii=False, indent=2), encoding="utf-8")
    (OUT / "enrichment.json").write_text(json.dumps(enrich, ensure_ascii=False, indent=2), encoding="utf-8")

    with_photo = len(people) - len(no_photo) - len(photo_fail)
    report = [
        f"CSV rows with a LinkedIn URL: {len(rows)}",
        f"Profiles matched:             {len(people)}",
        f"Photos downloaded:            {with_photo}",
        f"Posts found for:              {sum(1 for pid in enrich if enrich[pid]['recentPosts'])} people",
        "",
        f"NO PROFILE ({len(no_profile)}): " + "; ".join(no_profile),
        f"NO PHOTO on LinkedIn ({len(no_photo)}): " + "; ".join(no_photo),
        f"PHOTO DOWNLOAD FAILED ({len(photo_fail)}): " + "; ".join(photo_fail),
    ]
    (OUT / "report.txt").write_text("\n".join(report), encoding="utf-8")
    print("\n".join(report))


if __name__ == "__main__":
    main()
