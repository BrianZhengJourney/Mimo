# DIY 伴灵 — pipeline evaluation & new strategy

> 2026-07-17. Written after auditing the full DIY generation + render path.
> Trigger: generated **人像 (human-portrait) familiars render too small and the
> palette looks washed-out**, while pixel-art mascots look right.

## TL;DR

The whole pipeline is a **pixel-sprite pipeline**. The realistic/人像 path is being
forced through the *same* machinery (full-body framing, fit-to-square, legacy opaque alpha
matte, nearest-neighbor downscale, pixel-sized viewBox). Pixel art tolerates all of
this; a raster human portrait does not — so it comes out tiny and ugly.

Fix = **stop routing raster portraits through the pixel machine**, and split DIY into
two lanes that map exactly onto the goal ("可抽象、可具象"):

- **Lane A — 抽象伴灵 (procedural, code-drawn):** always 好看, deeply interactive, $0.
- **Lane B — 具象伴灵 (image-model, raster-native):** bust/big-head framing,
  crop-to-subject, soft alpha, its own render size — no pixel-sprite contract.

---

## Current pipeline (as built)

Model: **OpenAI `gpt-image-2`** via `/v1/images/edits` (`pet_generation.swift:944-961`).
Not PixelLab — the prototype debated PixelLab, shipped code uses GPT Image.

1. **Reference preprocess** (`reference_preprocessor.swift`) — Vision detects people,
   crops to subject, removes background, blurs text, tiles a 1024² identity board.
   *Does the right thing to the input — crops the person to fill frame.*
2. **Pass 1 — 3 Low drafts** (1024², `candidateBoardRequest`).
3. **Pass 2 — 3-form evolution sheet** (1536×1024, Seed/Bloom/Radiant).
4. **Normalize** (`character_sheet.swift`) — fit each form into a 512² cell, binary
   matte, store 1536×512 transparent sheet.
5. **Render** (`overlay.html`) — SVG `<image>` blitted into a fixed 22×22 clip box
   inside a 150px `.familiar` stage.

## Root cause — why 人像 is SMALL

Compounding, not one bug:

| # | Cause | File |
|---|-------|------|
| 1 | Prompt mandates **full body, feet fully visible, "tiny full body", "readable at 96–160px", "generous clear margin"** | `pet_generation.swift:608-616` |
| 2 | Figure confined to **central ~70–76%** of an already-1/3-subdivided panel | `pet_generation.swift:785-787` |
| 3 | Normalize **fits a tall figure into a 512² square** by height → ~150px wide → huge transparent side margins baked into the PNG | `character_sheet.swift:247-251` |
| 4 | Overlay **blits the whole padded 512² cell into a fixed 22×22 box** — never re-crops to the creature's alpha bounds | `overlay.html:1036-1057` |
| 5 | Raster viewBox `-1 -2 24 25` is **bigger than pixel `-1 -1 22 18`** → extra ~12% shrink | `overlay.html:984, 564` |

A desktop pet is ~150px. A full human body at 150px tall → the **face is ~20px**.
That's the "太小" feeling: not the whole image is small, the *recognizable part* is.
Pixel mascots dodge this because they're big-head chibi that fill the square.

## Root cause — why the COLOR looks bad

| Cause | File |
|-------|------|
| **Legacy opaque alpha matte (fixed 2026-07-28)** — the audit found foreground alpha forced to 255; current extraction uses feathered warm-matte edges and premultiplied RGBA chroma repair | `character_sheet.swift` |
| **Nearest-neighbor downscale** (`interpolationQuality = .none`, `floor()` sampling) → aliasing on a photo | `character_sheet.swift:553, 976-979` |
| **State CSS filters hue-rotate/desaturate the whole portrait** (poisoned `saturate(.58) hue-rotate(45deg)`, ghost `hue-rotate(175deg)`, etc.) → sickly face | `overlay.html:997-1001, 1130` |
| **Opaque `#F1ECE2` background** then crudely keyed out | `pet_generation.swift:627, 955` |

None of these hurt pixel art. All of them hurt a portrait.

---

## New strategy — two lanes

The goal literally says "可以是抽象的，也可以是很具象的". Build that as the top-level
choice, and give each lane a pipeline it can actually be beautiful in.

### Lane A — 抽象伴灵 (procedural / code-drawn)  ← recommended flagship

A creature drawn by **code**, not by an image model: layered SVG/gradients + a few
particles, parametrized by a handful of seeds (base hue, accent, blob-count, motion
personality). Fits the existing SVG render + state/house-rig system directly.

- **Always 好看** — designed by us, not a per-generation lottery.
- **Deeply interactive** — reacts to focus/distraction via params (pulse, drift,
  color-shift, particle density) far more expressively than a static sprite sheet.
- **$0, instant, private** — no API, no cost console, no send-confirmation gate.
- Maps to the app's soul (feeds on focus, corrupts with distraction) better than any
  photo ever could.

This is the strongest "interactive + 好看 + abstract" answer and it sidesteps the
image-model quality problem entirely.

### Lane B — 具象伴灵 (image-model, raster-native)

Keep GPT Image for people who want likeness — but stop pretending it's a pixel sprite.

1. **Bust / big-head framing, not full body.** Prompt for head-and-shoulders (or
   big-head chibi). At 150px a bust puts the face at ~80–100px → reads great, feels
   the right size. This alone fixes most of "太小".
2. **Crop-to-subject after generation.** Trim to alpha bounding box before storing, so
   the figure fills its cell instead of floating in matte. (New step between normalize
   and store.)
3. **Raster-native render.** Soft/anti-aliased alpha matte + **bilinear/Lanczos**
   downscale (not nearest-neighbor). Give raster its **own larger viewBox/render size**,
   decoupled from the 22×22 pixel box.
4. **Don't hue-rotate raster.** Gate the state filters: pixel packs keep them; raster
   packs get gentler treatments (dim/blur, no hue shift) so faces don't go sickly.
5. **Anchor scale to the face, not the canvas.** Size the on-screen creature from the
   detected face/subject bounds, not the padded frame.

---

## Prioritized improvements

**P0 — make the current portrait not-bad (small, targeted):**
- Bust framing in the prompt (`pet_generation.swift` layout block).
- Crop-to-alpha-bounds step (`character_sheet.swift`, after normalize).
- Soft matte + bilinear downscale for the raster path (`character_sheet.swift`).
- Skip/soften hue-rotate filters for raster packs (`overlay.html`).

**P1 — raster gets its own render size** decoupled from the pixel 22×22 box.

**P2 — Lane A procedural abstract creature** (new pack type in the SVG renderer +
a simple param picker in the DIY UI). Highest long-term payoff.

**P3 — DIY UX declutter** (from the audit): the cost console, "身份板/OpenAI/matte"
jargon, and the auto-start-countdown-that-spends-money all leak pipeline internals to
a creative flow. A top-level 抽象/具象 choice reframes the whole thing.

## Open question — should the pixel lane keep GPT Image?

The prototype's Route B recommended **PixelLab** (purpose-built pixel-art + animation
API) for the pixel look. Current code coaxes GPT Image into "pixel-inspired" style with
a long prompt. If the pixel mascots are the ones that already look right, this is lower
priority — but worth revisiting if you want true pixel-grid output + rigged animation.
