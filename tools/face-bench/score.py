import json, sys, collections
S=sys.argv[1]; gt=json.load(open(f"{S}/gt.json"))
res=json.load(open(f"{S}/py_results.json")); res.update(json.load(open(f"{S}/vision_results.json")))
def iou(a,b):
    ix=max(0,min(a[2],b[2])-max(a[0],b[0])); iy=max(0,min(a[3],b[3])-max(a[1],b[1])); i=ix*iy
    return i/((a[2]-a[0])*(a[3]-a[1])+(b[2]-b[0])*(b[3]-b[1])-i+1e-9)
def hit(g,d):
    cx,cy=(g[0]+g[2])/2,(g[1]+g[3])/2
    return iou(g,d)>=0.3 or (d[0]<=cx<=d[2] and d[1]<=cy<=d[3] and (d[2]-d[0])<3*(g[2]-g[0]))
widths=[24,32,48,64,96]
for var in ("clean","blur"):
    print(f"\n{var:6s} face width px:", "  ".join(f"{w:>4}" for w in widths), "   extra boxes")
    for name,r in res.items():
        row=[]; fp=0
        for w in widths:
            keys=[k for k in gt if k.endswith(f"_w{w}_{var}.jpg")]
            ok=sum(any(hit(gt[k],d) for d in r.get(k,[])) for k in keys)
            fp+=sum(sum(not hit(gt[k],d) for d in r.get(k,[])) for k in keys)
            row.append(f"{100*ok/len(keys):3.0f}%")
        print(f"  {name:12s}", "  ".join(f"{x:>4}" for x in row), f"   {fp}")
