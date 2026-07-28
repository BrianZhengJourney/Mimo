---
name: mimo-animate-pet
description: Design, generate, repair, validate, and package the approved high-fidelity Mimo companion actions—idle breathing, walking, sleep transitions and breathing, eight-direction gaze, tennis, and wall stand/sit—with chained three-frame generation, shared 512px geometry, canonical identity references, conservative transparency, authored timing, and deterministic QA. Use when creating or fixing one of these Mimo DIY animation assets or diagnosing identity drift, hair-matte loss, size popping, baseline jitter, or motion timing.
---

# Mimo Animate Pet

Create one polished Mimo action at a time. Preserve Mimo's high-fidelity
`512×512` cells while borrowing HatchPet's dependency graph, canonical identity
lock, coherent-family generation, deterministic registration, and QA gates.

## Required references

- Read [identity-and-fidelity.md](references/identity-and-fidelity.md) before
  preparing or repairing generated frames.
- Read [motion-tempo.md](references/motion-tempo.md) before choosing frame
  counts, holds, FPS, behavior timing, or locomotion cycle distance.
- For implementation inside the Mimo repository, also inspect:
  `mac/action_sheet.swift`, `mac/pet_generation.swift`,
  `mac/consistency_metric.swift`, and `mac/assets/behavior/default.json`.

## Non-negotiable contract

1. Keep the approved Mimo stage design as the canonical master. Never regenerate
   a lower-detail base merely to make animation easier.
2. Generate exactly one coherent three-frame batch per call. Approve it before
   the next chained batch. Never generate final frames independently.
3. Keep native action cells at `512×512`. Do not adopt HatchPet's `192×208`
   fidelity ceiling.
4. Attach the same canonical master, identity evidence, style board, layout
   guide, and motion guide to every visual pass where they exist.
5. Normalize all frames with one shared scale, baseline, and authored anchor.
   Never fit each frame independently.
6. Slow ambient motion with authored frame holds and behavior residency, not
   with many nearly identical generated frames.
7. Drive walking phase from distance travelled and authored cycle distance.
   FPS is only a preview fallback.
8. Prefer direct RGBA transparency. A chroma fallback must use zero alpha-edge
   contraction; despill may change RGB only. Inspect hair on light, dark, and
   checkerboard backgrounds.
9. Repair deterministic failures deterministically. Regenerate the complete
   three-frame batch when identity, rendering, anatomy, or source motion is wrong.

## Production action roster

The in-app Starter Action pack is the activation contract:

| Action | Final frames | Generation |
|---|---:|---|
| Sleep | 9 | lie-down `3` + breathing `3` + rise `3` |
| Gaze | 8 | up / upper-right / right `3` + lower-right / down / lower-left `3` + left / upper-left `2` |
| Tennis | 9 | preparation `3` + hit `3` + recovery `3` |
| Wall | 6 | wall-standing `3` + ledge-sitting `3` |
| Walk | 8 | `3 + 3 + 2`; mirror for the other direction |

The extended production tooling may also prepare:

| Action | Final frames | Generation |
|---|---:|---|
| Idle / breathing | 3 | one batch |

Do not add wave, run, jump, sit, work, wait, review, failure, celebration, or
other actions unless the user explicitly revises this roster. Historical outputs
may remain as rejected provenance but must not appear as production choices.

## Workflow

Keep one visible step active at a time:

1. Locking the character.
2. Authoring the motion and tempo.
3. Generating the coherent family.
4. Registering and validating.
5. Previewing at real size.

### 1. Lock the character

Select one approved, highest-fidelity stage frame as
`references/canonical-master.*`. Treat it as the absolute authority for face,
hair, markings, clothes, materials, palette, proportions, line weight, lighting,
and detail density.

Preserve useful identity evidence, but do not let collages or motion references
override the canonical master. Use the priority:

```text
canonical master > identity evidence > accepted action family > style board
> motion/layout guides
```

Record the stable traits that must remain readable at final display size. For a
person, include face construction, hair silhouette, body proportions, clothing
cut, handed markings, watch/tattoo/accessory placement, and habitual bearing.

### 2. Author motion and tempo

Classify the action before drawing:

- `ambient`: idle breathing, wall-standing, or ledge-sitting
- `segmented`: sleep lie-down → breathing loop → rise
- `locomotion`: walk
- `directional`: gaze
- `gesture`: tennis

Write the motion as named phases, including the loop seam. Prefer 4–8 strong
key poses. Use an inbetween pass only for large continuous motion. Do not ask an
image model for 16 subtly different ambient frames.

Choose holds and residency from `references/motion-tempo.md`. Split a long
sequence into transition and loop segments when they need different timing,
for example:

```text
rest-enter (quick one-shot) → sleep-loop (very slow) → rest-rise (quick one-shot)
```

### 3. Prepare the run

Before running bundled Python scripts, load workspace dependencies and use the
exact bundled Python path.

```bash
"$PYTHON" scripts/prepare_action_run.py \
  --canonical-master /absolute/path/to/approved-stage.png \
  --action sleep \
  --output-dir /absolute/path/to/run \
  --identity-notes "stable visual traits" \
  --style-board /absolute/path/to/mimo-style-board.png \
  --motion-guide /absolute/path/to/motion-guide.png \
  --force
```

Inspect `action-request.json`, `imagegen-jobs.json`, the prompt files, and the
layout guide before generating. The script prepares work; it never generates
visuals.

### 4. Generate the coherent family

Use `$imagegen` for visual generation. Attach every input listed for the ready
job in `imagegen-jobs.json`.

Generate `batch-01` first and approve it. Every later job receives the canonical
master plus the immediately preceding approved batch. The canonical master
always outranks chained evidence so errors cannot accumulate.

For walk, keep `K1–K3`, then `K4–K6`, then `K7–K8`; the third slot in the last
batch recreates `K1` only to test the loop seam and is discarded. Start with the
eight approved key poses. Add local midpoint batches only after a real-size
preview proves they are necessary.

For tennis, keep the racket identical across all batches and draw no ball. The
runtime owns one deterministic ball trajectory, preventing duplicate or drifting
balls.

Do not:

- generate one final frame per call
- ask the model to redraw the canonical master in a simpler style
- mix final frames from unrelated generations
- use prompt-only generation after the canonical master exists
- add labels, borders, visible guides, shadows, speed lines, or detached effects

If a result is wrong, classify the failure before retrying:

- identity/render/anatomy/motion semantics → regenerate the current three-frame batch
- layout, matte, extraction, scale, baseline, anchor → deterministic correction
- one weak pose inside an otherwise coherent batch → regenerate that whole batch;
  do not silently splice an unrelated single frame into the final loop

### 5. Register and validate

Use Mimo's `ActionSheetProcessor`: one scale for every frame, one baseline, and
one fixed authored anchor. Preserve source cells for QA.

Run:

```bash
"$PYTHON" scripts/validate_action_run.py /absolute/path/to/run
```

Then produce and inspect:

- raw generated sheet
- normalized horizontal strip
- 1× contact sheet
- transparent-background GIF/WebP preview using authored holds
- alpha contact sheets on light, dark, and checkerboard backgrounds
- identity/scale/anchor report
- run summary with prompt, references, model, cost, retries, and accepted asset

### 6. Acceptance

Accept only when all are true:

- the same person/pet is immediately recognizable in every frame
- face, hair, outfit, markings, palette, lighting, and detail density stay fixed
- no frame is visibly simplified relative to the canonical master
- the loop has no scale pop, baseline hop, foot skate, phase reversal, or seam
- ambient motion reads slowly and calmly at actual desktop size
- locomotion is phase-locked to travel distance
- generated imagery contains no visible guide, grid, label, effect debris, or
  chroma residue
- every retry and paid call is recorded

Do not install automatically after deterministic checks alone. Require a
real-size motion preview and explicit visual acceptance.
