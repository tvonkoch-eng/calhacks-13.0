import sys, json, time, glob, os
sys.path.insert(0, os.environ.get("FACETAG_SRC", os.path.expanduser("~/Developer/facetag/src")))
import numpy as np, cv2, onnxruntime as ort
from facetag.detect import FaceDetector
S, refs, mode = sys.argv[1], sys.argv[2], sys.argv[3]
def scrfd(path, size=640):
    return FaceDetector(ort.InferenceSession(path, providers=["CPUExecutionProvider"]), size=size, score_thresh=0.5)
big = scrfd(os.environ.get("SCRFD_10G", os.path.expanduser("~/Developer/facetag/models/det_10g.onnx")))
if mode == "gen":
    rng = np.random.default_rng(1); gt = {}
    for f in sorted(glob.glob(refs + "/*.jpg")):
        img = cv2.imread(f); b, _ = big.detect(img)
        if len(b) == 0: continue
        i = int(np.argmax((b[:,2]-b[:,0])*(b[:,3]-b[:,1]))); x1,y1,x2,y2,_ = b[i]; fw = x2-x1
        for W in (24, 32, 48, 64, 96):
            s = W / fw; r = cv2.resize(img, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
            cx, cy = (x1+x2)/2*s, (y1+y2)/2*s
            canvas = np.full((896, 504, 3), 110, np.uint8)
            # face lands at a random spot in the middle 60% of the frame
            tx, ty = rng.uniform(0.2,0.8)*504, rng.uniform(0.25,0.7)*896
            ox, oy = int(tx-cx), int(ty-cy)
            sx0, sy0 = max(0,-ox), max(0,-oy); dx0, dy0 = max(0,ox), max(0,oy)
            w = min(r.shape[1]-sx0, 504-dx0); h = min(r.shape[0]-sy0, 896-dy0)
            canvas[dy0:dy0+h, dx0:dx0+w] = r[sy0:sy0+h, sx0:sx0+w]
            box = [float(v) for v in (x1*s+ox, y1*s+oy, x2*s+ox, y2*s+oy)]
            for var in ("clean", "blur"):
                im = canvas
                if var == "blur":
                    k = np.zeros((7,7), np.float32); k[3,:] = 1/7
                    im = cv2.filter2D(canvas, -1, k)
                    im = cv2.imdecode(cv2.imencode(".jpg", im, [cv2.IMWRITE_JPEG_QUALITY, 55])[1], 1)
                name = f"{os.path.basename(f)[:-4]}_w{W}_{var}.jpg"
                cv2.imwrite(f"{S}/frames/{name}", im, [cv2.IMWRITE_JPEG_QUALITY, 92]); gt[name] = box
    json.dump(gt, open(f"{S}/gt.json","w")); print(len(gt), "frames")
else:
    small = scrfd(os.path.expanduser(refs))  # refs = det_500m path in this mode
    big640 = big
    yn = cv2.FaceDetectorYN.create(f"{S}/yunet.onnx", "", (504, 896), 0.6, 0.3, 50)
    out = {}
    def run(name, fn):
        res, t = {}, []
        for f in sorted(glob.glob(f"{S}/frames/*.jpg")):
            im = cv2.imread(f); t0 = time.perf_counter(); boxes = fn(im); t.append(time.perf_counter()-t0)
            res[os.path.basename(f)] = [list(map(float, b)) for b in boxes]
        out[name] = res; print(name, "median ms", round(np.median(t)*1000,1))
    run("scrfd_10g", lambda im: [b[:4] for b in big640.detect(im)[0]])
    run("scrfd_500m", lambda im: [b[:4] for b in small.detect(im)[0]])
    def y(im):
        _, f = yn.detect(im); return [] if f is None else [[a[0],a[1],a[0]+a[2],a[1]+a[3]] for a in f]
    run("yunet", y)
    json.dump(out, open(f"{S}/py_results.json","w"))
