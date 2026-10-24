import json,time,urllib.request,sys
KEY=[l.split('=')[1].strip() for l in open('/root/workspace/calhacks-13.0/Secrets.xcconfig') if 'ANSWER_API_KEY' in l][0]
SYS="""You are a discreet aid on smart glasses worn during an in-person conversation. You see the live transcript. After each new line you may put ONE short side note on the wearer's lens, or nothing. Nothing is the right answer almost every time: a note that is not clearly useful is a distraction.

Show a note only for one of these:
- correct: someone states a checkable fact about the world that is clearly wrong. Give the right fact. ("Jupiter has 95 known moons, not 79")
- explain: a specific proper noun or technical term the wearer may not know (a company, product, place, notable person, acronym, jargon). Say what it is. Skip everyday words and anything already explained.
- convert: a number in a unit or currency people often have to convert (Celsius, kilometers, euros, pounds). Give the other unit.
- recall: the speaker is clearly searching for a word or name ("what's that thing called", "the guy who…"). Supply it.

Never comment on the people themselves, their feelings, plans, appearance or private life. No advice, opinions, jokes or summaries. Never answer a question (another system does that). If unsure the fact is right, say nothing.

Reply with JSON only: {"kind":"none|correct|explain|convert|recall","note":"at most 10 words, no trailing period","topic":"the word or claim it is about"}"""
convo=[
 ("We went to Target in the Presidio area.", "explain?"),
 ("I mean, we can give it some agent usage as well.", "none"),
 ("We're using Groq, with a Q, for the answers.", "explain"),
 ("Okay, so fast.", "none"),
 ("Jupiter has like 79 moons, right, so that's the answer.", "correct"),
 ("I'm so tired, I barely slept last night.", "none"),
 ("It was like 30 degrees in Lisbon when we went.", "convert"),
 ("We should grab dinner after the judging.", "none"),
 ("We could use that thing, what's it called, the Apple framework for on-device speech.", "recall"),
 ("The demo went really well I think.", "none"),
 ("Honestly the Eiffel Tower is in Rome, which is wild.", "correct"),
 ("He was talking about RAG pipelines the whole time.", "explain"),
 ("Yeah, totally.", "none"),
 ("My brother works at Anthropic now.", "none?"),
 ("The rent was like 2000 euros a month.", "convert"),
 ("And this is all data that I can use with Groq.", "none"),
]
H={"Authorization":f"Bearer {KEY}","Content-Type":"application/json","User-Agent":"x/1"}
def ask(model, hist, line, shown):
    user=("Earlier:\n"+"\n".join(hist[-4:])+"\n\n" if hist else "")+("Notes already shown: "+"; ".join(shown)+"\n\n" if shown else "")+"New line: "+line
    b={"model":model,"temperature":0,"max_tokens":400,"response_format":{"type":"json_object"},"messages":[{"role":"system","content":SYS},{"role":"user","content":user}]}
    if "gpt-oss" in model: b["reasoning_effort"]="low"
    for a in range(4):
        try:
            t=time.time(); r=urllib.request.urlopen(urllib.request.Request("https://api.groq.com/openai/v1/chat/completions",data=json.dumps(b).encode(),headers=H),timeout=30)
            d=json.load(r); return json.loads(d["choices"][0]["message"]["content"]), time.time()-t, d["usage"]["total_tokens"]
        except Exception as e: time.sleep(3)
    return {"kind":"ERR"},0,0
for model in sys.argv[1:]:
    print("==",model); hist=[]; shown=[]; lats=[]; toks=0
    for line,want in convo:
        v,lat,tk=ask(model,hist,line,shown); lats.append(lat); toks+=tk
        ok = (v.get("kind")=="none")==(want.startswith("none")) or want.endswith("?")
        print(f"  {'ok ' if ok else 'BAD'} {want:9} {lat:.2f}s {v.get('kind'):8} {v.get('note','')!s:55} | {line[:50]}")
        if v.get("kind") not in ("none","ERR"): shown.append(v.get("note",""))
        hist.append(line)
    print("   median %.2fs, %d tokens total"%(sorted(lats)[len(lats)//2],toks))
