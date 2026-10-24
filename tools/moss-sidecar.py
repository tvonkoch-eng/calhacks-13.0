"""Moss as an instant answer tier for tools/live-mac.swift. Moss is on-device semantic search, not a
model: it can only return answers it already holds, but it returns them in ~2 ms. So the index is
seeded with the teammates' profiles and learns every answer the models give; a question already
answered, however it is reworded, comes back instantly.

    GET  /q?text=...           -> {"hit": bool, "answer", "question", "score", "ms"}
    POST /add {"q": , "a": }   -> {"ok": true}

Started by tools/live-mac.sh. Needs MOSS_PROJECT_ID / MOSS_PROJECT_KEY and `pip install moss`.
"""
import asyncio, json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from moss import DocumentInfo, MossClient, QueryOptions

PORT = int(os.environ.get("MOSS_PORT", "8765"))
# True rewordings scored 1.000 in testing; "how hot is the sun" vs "how big is the sun" scored 0.72.
HIT = float(os.environ.get("MOSS_HIT", "0.9"))
PEOPLE = sys.argv[1] if len(sys.argv) > 1 else "App/people.json"

loop = asyncio.new_event_loop()
threading.Thread(target=loop.run_forever, daemon=True).start()
run = lambda coro: asyncio.run_coroutine_threadsafe(coro, loop).result()

client = MossClient(os.environ["MOSS_PROJECT_ID"], os.environ["MOSS_PROJECT_KEY"])
session = run(client.session("calhacks-live", auto_load_on_init=False))
learned = 0


def seed():
    """A few spoken phrasings per profile fact. The document is the question; the answer rides in metadata."""
    docs = []
    for p in json.load(open(PEOPLE)):
        if p.get("isMe"):
            continue
        first = p["name"].split()[0]
        facts = {
            "school": [f"where does {first} go to school", f"what does {first} study", f"what college is {first} at"],
            "work": [f"where does {first} work", f"what does {first} do", f"what's {first}'s job"],
            "from": [f"where is {first} from", f"where did {first} grow up"],
            "interests": [f"what is {first} into", f"what does {first} like"],
        }
        for field, phrasings in facts.items():
            if p.get(field):
                for i, q in enumerate(phrasings):
                    docs.append(DocumentInfo(id=f"{p['id']}-{field}-{i}", text=q,
                                             metadata={"answer": p[field]}))
    run(session.add_docs(docs))
    return len(docs)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        text = parse_qs(urlparse(self.path).query).get("text", [""])[0]
        start = time.perf_counter()
        result = run(session.query(text, QueryOptions(top_k=1, alpha=0.8)))
        ms = (time.perf_counter() - start) * 1000
        if not result.docs:
            return self.reply({"hit": False, "ms": ms})
        doc = result.docs[0]
        self.reply({"hit": doc.score >= HIT, "score": doc.score, "ms": ms, "question": doc.text,
                    "answer": (doc.metadata or {}).get("answer", "")})

    def do_POST(self):
        global learned
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        learned += 1
        run(session.add_docs([DocumentInfo(id=f"learned-{learned}", text=body["q"],
                                           metadata={"answer": body["a"]})]))
        self.reply({"ok": True})


count = seed()
print(f"moss: {count} profile questions indexed, hit >= {HIT}, http://127.0.0.1:{PORT}", flush=True)
ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
