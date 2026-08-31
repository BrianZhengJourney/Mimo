# Wan action postprocessor

> Deterministic local packaging step, checked 2026-08-31. It does not generate video and cannot bypass Mimo's QA / explicit-accept gate.

Deterministically turns one fixed-camera Wan MP4 (or RGBA PNG sequence) into a
24-frame Mimo action strip. It does **not** generate or interpolate motion.

```text
Wan clip + phase.json
        │
        ├─ phase sample: [start, endExclusive)
        ├─ matte: source alpha, else declared matteRGB
        ├─ one cycle-union crop / scale / anchor
        └─ seam + geometry + clipping QA
        │
        ├─ action-walk.png
        ├─ action-walk.metadata.json
        ├─ action-walk.qa.json
        └─ action-walk-contact-sheet.png
```

Run from the repository root:

```bash
python3 -m mac.tools.wan_action.postprocess \
  --input artifacts/wan/runs/mimo-side-walk-v1-20260722/output/wan-raw.mp4 \
  --phase mac/assets/motion-driver/mimo-side-walk-v1/phase.json \
  --output-dir artifacts/wan/runs/mimo-side-walk-v1-20260722/mimo-preview \
  --cycle-distance-cell-pixels 144
```

`cycleDistanceCellPixels` is the authored distance covered by one complete
left-plus-right cycle, measured in a 512 px Mimo cell. It is never guessed.
For `walk`, omitting both the CLI value and sidecar value still produces a
preview, but the QA gate fails and Mimo must refuse installation.

The repository driver's flat `phase.json` shape is authoritative. The frame at
`cycleEndFrameExclusive` must exist as the first frame of the next cycle: it is
used only for closure QA and is never packed as a duplicate endpoint. A legacy
nested `cycle.startFrame` / `cycle.endFrame` sidecar is also accepted.

Wan MP4 is normally opaque. Add `"matteRGB": [r, g, b]` to a job-specific copy
of the sidecar when it was rendered over a known solid matte. RGBA PNG input
uses its alpha directly. Unknown opaque backgrounds fail closed; SAM/DINO are
intentionally outside this lightweight deterministic stage.

`sourceAnchorMode` defaults to `union-bottom-center`: the anchor is calculated
once from the alpha union of the full cycle and is never re-derived per frame.
An explicit `sourceAnchor: [x, y]` remains supported for authored fixtures.

For fidelity-controlled jobs, declare `"targetCharacterHeight": 451` in the
phase sidecar. The processor derives one scale from the median source alpha
bbox height and applies that same matrix to every frame. It rejects a target
that cannot fit the fixed anchor plus padding; it never silently shrinks the
target or normalizes individual frames. Sidecars without this optional field
retain the legacy cycle-union fit for compatibility.

P1 hard QA requires alpha closure ≥ 0.97, closure appearance error ≤ 0.05,
loop-seam/internal-P90 ratio ≤ 1.25, alpha-area deviation ≤ 0.12, and target
height within ±2%. Head/face size stability remains an explicit manual check:
without pose or face landmarks, an alpha-only heuristic cannot distinguish a
head from ears, hair, raised limbs, tails, or shadows reliably.

Tests:

```bash
python3 -m unittest mac.tools.wan_action.test_postprocess -v
```
