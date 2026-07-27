# Mimo × Wan2.2-Animate (private Modal batch)

This runner pins the official sources and keeps the expensive stage behind a
human pose/face review gate.

| Stage | Compute | Gate / output |
|---|---:|---|
| `download-preprocess` | CPU, small checkpoint | det + pose2d only |
| `preprocess` | L4, max 15 min | authoritative `cycle-contact-sheet.jpg`; frozen + dynamic face controls |
| manual `approve` | local | approval is bound to this exact preprocess ID |
| `validate-inputs` | CPU, no GPU | exact 77-frame decode + approved hash marker |
| `download-inference` | CPU, ~52 GB | blocked before validation |
| `infer` | H200, max 30 min | RGB `wan-raw.mp4` + cost/provenance `run.json` |

Pins:

- Wan2.2 commit: `42bf4cfaa384bc21833865abc2f9e6c0e67233dc`
- `Wan-AI/Wan2.2-Animate-14B` revision:
  `cb93a225fbaf1ca100f54e79da8f994995b689b3`

## 0. No-network / no-GPU checks

Run from the repository root. The dry runs do not import Modal or contact its API.

```bash
/opt/anaconda3/bin/python3 -m unittest mac/tools/test_wan_modal_client.py mac/modal/test_wan_animate_app.py -v
/opt/anaconda3/bin/python3 -m py_compile mac/modal/wan_animate_app.py mac/tools/wan_modal_client.py
/opt/anaconda3/bin/python3 mac/tools/wan_modal_client.py upload \
  --job-id mimo-side-walk-v1-20260722 \
  --character mac/assets/motion-driver/mimo-side-walk-v1/character.png \
  --driver mac/assets/motion-driver/mimo-side-walk-v1/driver.mp4 \
  --width 512 --height 512 --frame-num 77 \
  --cycle-start-frame 24 --cycle-end-frame-exclusive 48 \
  --frozen-face-frame 24 --dry-run
/opt/anaconda3/bin/python3 mac/tools/wan_modal_client.py spawn \
  --stage preprocess --job-id mimo-side-walk-v1-20260722 --dry-run
```

## 1. Modal preflight and deploy

All commands explicitly scope the clean Mimo profile. Do **not** run
`modal profile activate`.

```bash
MODAL_PROFILE=brian-journey7 /opt/anaconda3/bin/modal profile current
MODAL_PROFILE=brian-journey7 /opt/anaconda3/bin/modal secret list --json
MODAL_PROFILE=brian-journey7 /opt/anaconda3/bin/modal deploy --help
MODAL_PROFILE=brian-journey7 /opt/anaconda3/bin/modal deploy mac/modal/wan_animate_app.py

MODAL_PROFILE=brian-journey7 /opt/anaconda3/bin/python3 mac/tools/wan_modal_client.py \
  spawn --stage preflight
```

Deploy builds the pinned image but does not request a GPU. The app expects the
existing private Modal secret named `huggingface` (normally containing
`HF_TOKEN`). The CUDA-devel base already contains the compiler toolchain, so
the image runs no apt step: Ninja is pinned from PyPI and the Wan/SAM2 source
archives are fetched by immutable commit URL. Face-control encoding uses the
pinned `imageio-ffmpeg` binary rather than the slow system ffmpeg package chain.

## 2. Cheap pose gate

Each `spawn` prints a `call_id`; substitute it in `status` until the result is
`finished`.

```bash
MODAL_PROFILE=brian-journey7 /opt/anaconda3/bin/python3 mac/tools/wan_modal_client.py \
  spawn --stage download-preprocess

MODAL_PROFILE=brian-journey7 /opt/anaconda3/bin/python3 mac/tools/wan_modal_client.py \
  upload --job-id mimo-side-walk-v1-20260722 \
  --character mac/assets/motion-driver/mimo-side-walk-v1/character.png \
  --driver mac/assets/motion-driver/mimo-side-walk-v1/driver.mp4 \
  --width 512 --height 512 --frame-num 77 --sample-steps 20 --seed 42 \
  --cycle-start-frame 24 --cycle-end-frame-exclusive 48 \
  --frozen-face-frame 24

MODAL_PROFILE=brian-journey7 /opt/anaconda3/bin/python3 mac/tools/wan_modal_client.py \
  spawn --stage preprocess --job-id mimo-side-walk-v1-20260722

MODAL_PROFILE=brian-journey7 /opt/anaconda3/bin/python3 mac/tools/wan_modal_client.py \
  status REPLACE_WITH_CALL_ID

MODAL_PROFILE=brian-journey7 /opt/anaconda3/bin/python3 mac/tools/wan_modal_client.py \
  download --job-id mimo-side-walk-v1-20260722 --stage preprocess \
  --out artifacts/wan/runs/mimo-side-walk-v1-20260722/preprocess-approved
```

`cycle-contact-sheet.jpg` is authoritative. It contains all 24 packed frames
`[24,48)` plus closure frame `48`, so its pose section is exactly frames 24…48
inclusive. It also compares dynamic and frozen-face rows. `src_face.mp4` is the
77-frame, 30fps control frozen from dynamic face frame 24;
`src_face-dynamic.mp4` preserves the official output. Check scale, crop, grounded
foot contacts, leg swaps, the closure, and both face rows. The overview is only a
convenience. Re-running `preprocess` invalidates the previous approval/output for
that job ID.

```bash
open artifacts/wan/runs/mimo-side-walk-v1-20260722/preprocess-approved/cycle-contact-sheet.jpg
open artifacts/wan/runs/mimo-side-walk-v1-20260722/preprocess-approved/overview-contact-sheet.jpg
open artifacts/wan/runs/mimo-side-walk-v1-20260722/preprocess-approved/src_pose.mp4
open artifacts/wan/runs/mimo-side-walk-v1-20260722/preprocess-approved/src_face.mp4
open artifacts/wan/runs/mimo-side-walk-v1-20260722/preprocess-approved/src_face-dynamic.mp4

MODAL_PROFILE=brian-journey7 /opt/anaconda3/bin/python3 mac/tools/wan_modal_client.py \
  approve --job-id mimo-side-walk-v1-20260722 --yes-reviewed-cycle-sheet \
  --note "reviewed packed 24..47 + closure 48, frozen/dynamic face rows"
```

## 3. Expensive weights and H200 inference

First run the jobs-only CPU gate. It copies the approved controls off Volume
FUSE, verifies every hash, fully decodes pose/face, and persists a marker bound
to request + metadata + READY + approval + authoritative sheet. Wan requires
exactly 77 frames here: the official pose encoder can emit one trailing packet,
so staging losslessly trims 78 → 77 while keeping the reviewed source hash.

The reference is also staged losslessly as an uncompressed BMP payload at Wan's
fixed `src_ref.png` path. OpenCV detects its file signature; this avoids the
libpng/zlib conflict observed only after the 14B model had loaded, without
changing a reference pixel. CPU validation and H200 repeat the same staging
function and must produce the same hashes.

```bash
MODAL_PROFILE=brian-journey7 /opt/anaconda3/bin/python3 mac/tools/wan_modal_client.py \
  spawn --stage validate-inputs --job-id mimo-side-walk-v1-20260722

MODAL_PROFILE=brian-journey7 /opt/anaconda3/bin/python3 mac/tools/wan_modal_client.py \
  spawn --stage download-inference --job-id mimo-side-walk-v1-20260722

MODAL_PROFILE=brian-journey7 /opt/anaconda3/bin/python3 mac/tools/wan_modal_client.py \
  spawn --stage infer --job-id mimo-side-walk-v1-20260722 --seed 42

MODAL_PROFILE=brian-journey7 /opt/anaconda3/bin/python3 mac/tools/wan_modal_client.py \
  download --job-id mimo-side-walk-v1-20260722 --stage output \
  --out artifacts/wan/runs/mimo-side-walk-v1-20260722/output
```

`run.json` records the measured function time, official pins, GPU-only estimate,
and the full Modal compute estimate. At the 2026-07 list-price snapshot, H200 +
8 CPU cores + 96 GiB is `$0.00157892/s` (~`$0.947/10 min`); the 30-minute hard
timeout caps that compute estimate at about `$2.842`. Volume storage is noted at
`$0.09/GiB-month` with the first `1 TiB/month` free and is not added to the run
estimate. Actual Modal billing can include image build/container startup.

Wan output is RGB video, not a transparent sprite. The separate local
postprocess step performs background removal, cycle selection, normalization and
Mimo sheet packaging only after `wan-raw.mp4` is downloaded.
