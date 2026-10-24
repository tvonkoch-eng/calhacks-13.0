import sys, numpy as np, onnx, onnxruntime as ort, torch, coremltools as ct
from onnx2torch import convert
src, dst = sys.argv[1], sys.argv[2]
m = onnx.load(src)
for d,v in zip(m.graph.input[0].type.tensor_type.shape.dim,(1,3,112,112)):
    d.ClearField("dim_param"); d.dim_value=v
mod = convert(m).eval()
traced = torch.jit.trace(mod, torch.zeros(1,3,112,112))
ml = ct.convert(traced, convert_to="neuralnetwork",
    inputs=[ct.ImageType(name="face", shape=(1,3,112,112), scale=1/127.5, bias=[-1,-1,-1], color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="embedding")], minimum_deployment_target=ct.target.iOS14)
ml.short_description="MobileFaceNet ArcFace w600k (InsightFace buffalo_s, non-commercial)"
ml.save(dst)
# parity check
from PIL import Image
rng=np.random.default_rng(0); img=(rng.random((112,112,3))*255).astype(np.uint8)
x=(img.astype(np.float32)/127.5-1).transpose(2,0,1)[None]
ref=ort.InferenceSession(src).run(None,{ort.InferenceSession(src).get_inputs()[0].name:x})[0].ravel()
out=ct.models.MLModel(dst).predict({"face":Image.fromarray(img)})["embedding"].ravel()
print("cosine parity", float(ref@out/np.linalg.norm(ref)/np.linalg.norm(out)), out.shape)
