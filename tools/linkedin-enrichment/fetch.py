"""Stage 1: pull LinkedIn profiles and recent posts for everyone in people.csv via Apify.

    python fetch.py --limit 2          # test on the first 2 people
    python fetch.py                    # everyone not already fetched
    python fetch.py --posts-max 5      # recent posts per person (default 5)

Raw actor output is cached in raw/ so reruns only pay for people not fetched yet.
The token is read from APIFY_TOKEN (environment or a .env file next to this script).
"""
import argparse
import csv
import json
import os
import sys
import time
import urllib.parse
from pathlib import Path

import requests

HERE = Path(__file__).parent
RAW = HERE / "raw"
API = "https://api.apify.com/v2"
PROFILE_ACTOR = "harvestapi~linkedin-profile-scraper"
POSTS_ACTOR = "harvestapi~linkedin-profile-posts"


def load_token() -> str:
    token = os.environ.get("APIFY_TOKEN", "").strip()
    env = HERE / ".env"
    if not token and env.exists():
        for line in env.read_text(encoding="utf-8").splitlines():
            if line.startswith("APIFY_TOKEN="):
                token = line.split("=", 1)[1].strip()
    if not token:
        sys.exit("APIFY_TOKEN is not set. Put it in .env (APIFY_TOKEN=...) or the environment.")
    return token


def run_actor(token: str, actor: str, body: dict, label: str) -> list[dict]:
    """Start a run, wait for it, return the dataset items."""
    h = {"Authorization": f"Bearer {token}"}
    r = requests.post(f"{API}/acts/{actor}/runs", json=body, headers=h, timeout=60)
    r.raise_for_status()
    run = r.json()["data"]
    print(f"[{label}] run {run['id']} started")
    while run["status"] in ("READY", "RUNNING"):
        time.sleep(5)
        run = requests.get(f"{API}/actor-runs/{run['id']}", headers=h, timeout=60).json()["data"]
        print(f"[{label}] {run['status']}", end="\r")
    print()
    if run["status"] != "SUCCEEDED":
        sys.exit(f"[{label}] run ended {run['status']}: {run.get('statusMessage')}")
    items = requests.get(
        f"{API}/datasets/{run['defaultDatasetId']}/items", params={"clean": "true"}, headers=h, timeout=120
    )
    items.raise_for_status()
    cost = run.get("usageTotalUsd")
    print(f"[{label}] {len(items.json())} items, cost ${cost}")
    return items.json()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0, help="only the first N people")
    ap.add_argument("--posts-max", type=int, default=5)
    ap.add_argument("--no-posts", action="store_true")
    args = ap.parse_args()

    token = load_token()
    RAW.mkdir(exist_ok=True)

    with open(HERE / "people.csv", encoding="utf-8-sig", newline="") as f:
        rows = [r for r in csv.DictReader(f) if (r.get("linkedin_url") or "").strip()]
    if args.limit:
        rows = rows[: args.limit]

    prof_path, post_path = RAW / "profiles.json", RAW / "posts.json"
    profiles = json.loads(prof_path.read_text(encoding="utf-8")) if prof_path.exists() else []
    posts = json.loads(post_path.read_text(encoding="utf-8")) if post_path.exists() else []

    def done_ids(items: list[dict]) -> set[str]:
        return {i.get("_queryUrl", "") for i in items}

    # Remember which URLs we've already asked for, so reruns don't pay twice.
    asked_path = RAW / "asked.json"
    asked = json.loads(asked_path.read_text(encoding="utf-8")) if asked_path.exists() else {"profiles": [], "posts": []}

    urls = [r["linkedin_url"].strip() for r in rows]
    todo = [u for u in urls if u not in asked["profiles"]]
    print(f"{len(urls)} people, {len(todo)} profiles to fetch")
    if todo:
        got = run_actor(
            token,
            PROFILE_ACTOR,
            {"profileScraperMode": "Profile details no email ($4 per 1k)", "urls": todo},
            "profiles",
        )
        profiles += got
        asked["profiles"] += todo
        prof_path.write_text(json.dumps(profiles, ensure_ascii=False, indent=1), encoding="utf-8")
        asked_path.write_text(json.dumps(asked, indent=1), encoding="utf-8")

    if not args.no_posts:
        todo = [u for u in urls if u not in asked["posts"]]
        print(f"{len(todo)} people to fetch posts for")
        if todo:
            got = run_actor(
                token,
                POSTS_ACTOR,
                {"targetUrls": todo, "maxPosts": args.posts_max, "includeReposts": False, "scrapeReactions": False, "scrapeComments": False},
                "posts",
            )
            posts += got
            asked["posts"] += todo
            post_path.write_text(json.dumps(posts, ensure_ascii=False, indent=1), encoding="utf-8")
            asked_path.write_text(json.dumps(asked, indent=1), encoding="utf-8")

    print(f"saved raw/profiles.json ({len(profiles)}) and raw/posts.json ({len(posts)})")


if __name__ == "__main__":
    main()
