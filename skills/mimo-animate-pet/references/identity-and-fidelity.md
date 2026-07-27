# Identity and fidelity

## Contents

1. What HatchPet actually does
2. Why its Mimo result is consistent but lower fidelity
3. The Mimo hybrid contract
4. Generation and repair units
5. QA gates

## 1. What HatchPet actually does

The inspected HatchPet run is not “one excellent prompt.” It is a staged
artifact graph:

```text
source references
      ↓
canonical base
      ↓
independent coherent state rows
      ↓
row extraction + immediate QA
      ↓
approved standard contact sheet
      ↓
4 cardinal gaze anchors
      ↓
look row 9
      ↓
look row 10
      ↓
shared registration + despill + atlas QA
```

Every state row receives the same original references, canonical base, and a
state-specific layout guide. Later rows additionally receive approved earlier
artifacts. Completion is dependency-gated; a selected image is not considered
complete until copied into the run and checked.

The run also retained seven rejected gaze attempts. Its consistency therefore
comes from constrained generation plus repeated evidence-based rejection, not
from guaranteed first-pass determinism.

## 2. Why it is lower fidelity

HatchPet deliberately targets a `192×208` final cell and instructs the model to
use:

- a compact pet-safe silhouette
- a simple face
- chunky outlines
- a limited palette
- flat cel shading
- visible stepped pixel edges

The generated source rows were larger, but final assembly reduced every pose to
the fixed `192×208` atlas cell. The result trades fine facial, clothing, and
material detail for readability and identity stability at tiny size.

Mimo's current action path uses `512×512` cells. Keep that fidelity budget.
Borrow the workflow, not the tiny-cell style contract.

## 3. Mimo hybrid contract

### Canonical identity lock

Use the already approved high-fidelity stage design. Do not generate a new
animation-friendly base. The canonical master is the source of truth for:

- facial geometry and habitual expression
- hair mass, parting, length, and motion character
- body and head proportions
- clothing cut, folds, trim, and value structure
- markings, tattoos, watch, jewelry, or asymmetric details
- outline weight, anti-aliasing, palette, lighting, and shading density
- the character's default bearing

### Stable reference stack

Attach references in the same order on every pass:

1. canonical master
2. compact identity evidence board, if needed
3. accepted action family, for inbetweens or whole-sheet edits
4. Mimo style board
5. motion guide
6. layout guide

State the role of each image. Motion and layout references never contribute
identity, color, anatomy, or rendering style.

### Preserve detail density

Prompts must say that pose is the only allowed change. Explicitly prohibit:

- mascot simplification
- larger/chunkier pixel blocks
- fewer colors or flatter shading
- genericized facial features
- redesigned clothes or accessories
- per-frame “improvements”

Review at the runtime display size and at 1× source cell size. A frame can be
structurally valid while visibly losing the face.

## 4. Generation and repair units

### Chained three-frame batches

Generate exactly three consecutive poses per call. Accept each batch before the
next call. Every later batch receives the canonical master and the immediately
preceding approved batch; canonical identity always wins.

For an eight-frame walk, keep `K1–K3`, `K4–K6`, then `K7–K8`. Use the third slot
of the last batch to recreate `K1` as a loop-seam check and discard it. Do not
generate all eight keyframes or all midpoints in one sheet.

### Gaze

Keep the head, face outline, body, and hair fixed. Generate one coherent
three-frame family: neutral eyes, screen-left eyes, screen-right eyes. Move only
the pupils/irises and, if needed, the eyelids. Head turns create new hair
silhouettes and are rejected for this action.

### Transparency and hair

Prefer native RGBA output. If a provider requires chroma cleanup:

- never contract the alpha edge;
- restrict despill to RGB;
- preserve the opaque dark outline and connected hair mass;
- inspect the matte on light, dark, and checkerboard backgrounds.

Treat any background-colored loop enclosed between the face/neck and a front
hair lock as missing hair, not legitimate negative space. Inspect every frame
enlarged on white as well as in a contact sheet; a small contact sheet can hide
this failure.

One-pixel erosion is a structural failure for pixel-styled hair, not harmless
cleanup.

### Repair

| Failure | Repair |
|---|---|
| Wrong matte, border, crop, slot, baseline, anchor | deterministic processing |
| Uniformly small repair family | one shared-scale normalization, bounded |
| One wrong motion phase but stable identity | regenerate its complete three-frame batch |
| Identity, face, outfit, anatomy, rendering drift | reject the batch; do not propagate it |
| Alpha hole differs across otherwise registered same-batch frames | copy only donor pixels that are opaque in the good frame and transparent in the target, restricted to the defective hair region |
| Repeated same failure twice | change strategy, frame budget, or pose construction |

Never solve identity drift by independently generating the failed final frame
and splicing it beside a different generation.

## 5. QA gates

### Deterministic

- exact expected frame count
- 512px output cells
- complete non-empty subject
- no source/cell-edge clipping
- shared scale and baseline
- fixed anchor in final strip
- alpha/matte cleanliness
- no contracted hair outline or transparent holes in the hair mass
- no unexpected components or visible guides

### Identity and fidelity

- compare every source cell with the same-stage canonical reference
- use Mimo's calibrated Vision feature-print ranges where view angle is
  compatible; do not reuse frontal thresholds blindly on side-profile walking
- inspect face, hair, asymmetric details, clothes, and palette at 1×
- reject detail-density collapse even if feature distance passes
- compare the row both to the canonical master and internally to detect
  one-frame drift

### Motion

- correct action semantics
- unique ordered phases
- no reversed phase, foot skate, duplicate wide stride, or inert loop
- no size pop, baseline hop, detached prop, or loop-seam snap
- authored playback at real desktop size

The quality gate is post-generation and mandatory. Neither OpenAI nor the
current Mimo providers expose a deterministic seed that can guarantee identity
before generation.
