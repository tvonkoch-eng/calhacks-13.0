import sys, numpy as np, onnx, onnxruntime as ort, torch, coremltools as ct, cv2
from onnx2torch import convert
from PIL import Image
src, dst, probe = sys.argv[1], sys.argv[2], sys.argv[3]
H, W = 896, 512
NAMES = [f"{k}_{s}" for k in ("score", "bbox", "kps") for s in (8, 16, 32)]
m = onnx.load(src)
for d, v in zip(m.graph.input[0].type.tensor_type.shape.dim, (1, 3, H, W)):
    d.ClearField("dim_param"); d.dim_value = v
mod = convert(m).eval()
traced = torch.jit.trace(mod, torch.zeros(1, 3, H, W))
ml = ct.convert(traced,
    inputs=[ct.ImageType(name="image", shape=(1, 3, H, W), scale=1/128, bias=[-127.5/128]*3, color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name=n) for n in NAMES],
    minimum_deployment_target=ct.target.iOS17, compute_precision=ct.precision.FLOAT16)
ml.short_description = "SCRFD-500M face detector, 512x896 portrait (InsightFace buffalo_s, non-commercial)"
ml.save(dst)
# parity on a real glasses-sized frame
img = cv2.imread(probe); canvas = np.zeros((H, W, 3), np.uint8); canvas[:img.shape[0], :img.shape[1]] = img[:H, :W]
rgb = canvas[:, :, ::-1]
x = ((rgb.astype(np.float32) - 127.5) / 128).transpose(2, 0, 1)[None]
sess = ort.InferenceSession(src); ref = sess.run(None, {sess.get_inputs()[0].name: x})
out = ct.models.MLModel(dst).predict({"image": Image.fromarray(np.ascontiguousarray(rgb))})
for i, n in enumerate(NAMES):
    a, b = ref[i].ravel(), np.asarray(out[n]).ravel()
    print(n, out[n].shape, "max abs diff", round(float(np.abs(a - b).max()), 4))
s = ref[0][:, 0]; t = np.asarray(out["score_8"])[:, 0]
print("faces>0.5 onnx", int((s > .5).sum()), "coreml", int((t > .5).sum()))
