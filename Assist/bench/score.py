import json,glob,re,collections
truth=json.load(open("truth.json"))
NUM={"twenty twenty two":"2022"}
def norm(s):
    s=s.lower()
    for k,v in NUM.items(): s=s.replace(k,v)
    s=s.replace("calhacks","cal hacks").replace("ray-ban","ray ban").replace("'","")
    return re.sub(r"[^a-z0-9 ]"," ",s).split()
def wer(r,h):
    d=list(range(len(h)+1))
    for i,rw in enumerate(r,1):
        p,d[0]=d[0],i
        for j,hw in enumerate(h,1):
            p,d[j]=d[j],min(d[j]+1,d[j-1]+1,p+(rw!=hw))
    return d[-1],len(r)
TERMS=["cal hacks","groq","presidio","palace of fine arts","joaquin","mirabelle","meta ray ban","jupiter","berlin wall","berkeley"]
rows=collections.defaultdict(lambda:[0,0,0,0])
for f in sorted(glob.glob("out-*.jsonl")):
    tag=f[4:-6]
    for l in open(f):
        r=json.loads(l); name=r["file"].split("/")[-1]; cond=r["file"].split("/")[-2]
        t=truth[name]; e,n=wer(norm(t),norm(r.get("text","")))
        key=(tag.rsplit("-",1)[0] if tag.endswith("mixed") else tag.rsplit("-",1)[0], cond)
        k=rows[key]; k[0]+=e; k[1]+=n
        tn=" ".join(norm(t)); hn=" ".join(norm(r.get("text","")))
        for term in TERMS:
            if term in tn: k[2]+=1; k[3]+= term in hn
models=sorted({k[0] for k in rows}); conds=["clean","noisy10","noisy5far"]
print("word error rate (lower is better) / key names heard right")
print("%-16s"%"engine"+"".join("%-22s"%c for c in conds))
for m in models:
    print("%-16s"%m+"".join(("%5.1f%%  names %2d/%2d    "%(100*rows[(m,c)][0]/rows[(m,c)][1],rows[(m,c)][3],rows[(m,c)][2]) if rows[(m,c)][1] else " "*22) for c in conds))
