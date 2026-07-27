# Higgsfield action postprocessor

Converts one fixed-camera Higgsfield MP4 on a flat `#FF00FF` matte into the
existing Mimo action format.

```text
Higgsfield MP4
      ↓
24 evenly sampled native frames
      ↓
border-connected chroma matte
      ↓
one union crop + one scale + one anchor for the whole clip
      ↓
transparent PNG strip + GIF/WebP + contact sheet + QA JSON
```

Run from the repository root with the bundled workspace Python:

```bash
"$PYTHON" -m mac.tools.higgsfield_action.postprocess \
  --input output/mimo-actions/higgsfield-video-v1/source/sleep.mp4 \
  --output-dir output/mimo-actions/higgsfield-video-v1/previews/sleep \
  --action sleep
```

The processor never performs per-frame fitting, which prevents normalization
from introducing size pops or baseline jumps.
