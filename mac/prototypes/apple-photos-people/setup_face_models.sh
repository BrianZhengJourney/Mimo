#!/bin/bash
# Restore the research-only local Photos identity models into persistent,
# Git-ignored storage used by both build.sh and the standalone prototype.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MAC_ROOT="$(cd "$HERE/../.." && pwd)"
LOCAL_ROOT="${MIMO_FACE_MODEL_HOME:-$MAC_ROOT/.local/face-model-setup}"
SOURCE_ROOT="$LOCAL_ROOT/sources"
PACKAGE_ROOT="$LOCAL_ROOT/coreml-packages"
COMPILED_ROOT="${MIMO_FACE_MODEL_DIR:-$MAC_ROOT/.local/face-models}"
VENV="$LOCAL_ROOT/venv-py311-v1"
UV_BIN="${UV_BIN:-$(command -v uv || true)}"

if [ -z "$UV_BIN" ]; then
  echo "error: uv is required to prepare the local model environment." >&2
  exit 1
fi

mkdir -p "$SOURCE_ROOT" "$PACKAGE_ROOT" "$COMPILED_ROOT"
if [ ! -x "$VENV/bin/python" ]; then
  "$UV_BIN" venv --python "${MIMO_FACE_MODEL_PYTHON:-python3.11}" "$VENV"
fi
"$UV_BIN" pip install --python "$VENV/bin/python" \
  'numpy>=1.26,<2' 'torch==2.7.0' 'torchvision==0.22.0' \
  'coremltools>=8,<10' 'huggingface_hub>=0.30,<2' \
  'omegaconf>=2.3,<3' 'einops>=0.8,<1' 'pillow>=10,<13' \
  'fvcore>=0.1.5,<0.2' 'timm>=1,<2' 'safetensors>=0.5,<1' \
  'easydict>=1.13,<2'

"$VENV/bin/python" - "$SOURCE_ROOT" <<'PY'
from pathlib import Path
import sys
from huggingface_hub import snapshot_download

root = Path(sys.argv[1])
models = [
    (
        "minchul/cvlface_adaface_ir101_webface12m",
        root / "adaface-ir101",
        ["models/**", "pretrained_model/model.pt"],
    ),
    (
        "minchul/cvlface_adaface_vit_base_kprpe_webface12m",
        root / "adaface-kprpe",
        ["config.json", "models/**", "pretrained_model/model.pt"],
    ),
]
for repo_id, destination, patterns in models:
    print(f"downloading={repo_id}")
    snapshot_download(
        repo_id=repo_id,
        local_dir=destination,
        allow_patterns=patterns,
    )
PY

"$VENV/bin/python" "$HERE/convert_face_models.py" \
  --model ir101 --ir101-dir "$SOURCE_ROOT/adaface-ir101" \
  --output-dir "$PACKAGE_ROOT"
"$VENV/bin/python" "$HERE/convert_face_models.py" \
  --model kprpe --kprpe-dir "$SOURCE_ROOT/adaface-kprpe" \
  --output-dir "$PACKAGE_ROOT"

for model in MimoAdaFaceIR101 MimoAdaFaceKPRPE; do
  target="$COMPILED_ROOT/$model.mlmodelc"
  rm -rf "$target"
  xcrun coremlcompiler compile "$PACKAGE_ROOT/$model.mlpackage" \
    "$COMPILED_ROOT"
done

source "$MAC_ROOT/face_models.sh"
for model in MimoAdaFaceIR101 MimoAdaFaceKPRPE; do
  if ! mimo_compiled_face_model_is_valid \
      "$COMPILED_ROOT/$model.mlmodelc"; then
    echo "error: compiled model is incomplete: $model" >&2
    exit 1
  fi
done

echo "ready: $COMPILED_ROOT"
