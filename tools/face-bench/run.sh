#!/bin/sh
# Detector + recognition bench on the bundled references, as glasses-sized frames.
#   sh tools/face-bench/run.sh [models-dir]   (default ~/Developer/calhacks-models)
# Needs a Python with onnxruntime, opencv-python, numpy and InsightFace's SCRFD decoder
# (PY, default: facetag's convert venv) and the compiled models next to the Swift harness.
set -e
cd "$(dirname "$0")/../.."
REPO=$(pwd)
MODELS=${1:-$HOME/Developer/calhacks-models}
PY=${PY:-$HOME/Developer/facetag/tools/.convert-venv/bin/python}
OUT=${OUT:-$(mktemp -d)}
mkdir -p "$OUT/frames" "$OUT/rec"
curl -sSL -o "$OUT/yunet.onnx" https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx
"$PY" -I tools/face-bench/detbench.py "$OUT" App/References gen
"$PY" -I tools/face-bench/detbench.py "$OUT" "$MODELS/det_500m.onnx" eval
swiftc -O tools/face-bench/vision.swift -o "$OUT/vision" && "$OUT/vision" "$OUT"
python3 -I tools/face-bench/score.py "$OUT"
# Recognition: the app's own FaceEngine (everything above PhoneCamera) on macOS.
sed -n '1,/^\/\/\/ Back\/front camera/p' App/Face.swift | sed '$d; s/^import SwiftUI$//' > "$OUT/rec/Face.swift"
cp App/FaceDetector.swift "$OUT/rec/"; cp tools/face-bench/rec_main.swift "$OUT/rec/main.swift"; cp tools/face-bench/rec_stubs.swift "$OUT/rec/Stubs.swift"
xcrun coremlc compile "$MODELS/SCRFD_500M.mlpackage" "$OUT/rec" >/dev/null
xcrun coremlc compile "$MODELS/MobileFaceNet_w600k.mlmodel" "$OUT/rec" >/dev/null
swiftc -O "$OUT"/rec/*.swift -o "$OUT/rec/rec"
for v in 0 1; do (cd "$OUT/rec" && useSCRFD=$v ./rec "$OUT" "$REPO/App/References" 2>/dev/null); done
