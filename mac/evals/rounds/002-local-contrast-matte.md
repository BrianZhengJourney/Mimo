# Round 002 — local-contrast matte edge recovery

## Baseline evidence

- Overall matte error: `1.4199%`.
- Pareto matte class: `light_subject_warm_matte`.
- Class score: `0.926097`.
- Boundary F1: `0.842497`.
- Foreground retention: `0.956341`.
- Background rejection: `1.0`.

## Ranked hypotheses

1. **Low-contrast antialias is flooded away.** Pale clothing is only about 21
   RGB-distance units from the warm matte. Its blended edge falls inside the
   matte threshold and becomes connected background. The perfect background
   rejection plus weak boundary/retention metrics support this.
2. **Normalization resampling contracts the subject.** Disproved for this
   fixture: the eval scores `removeBorderConnectedMatte` directly before any
   scale or registration.
3. **The matte color estimate is wrong.** Unlikely: common and variable warm
   matte classes are perfect, and the extracted background rejection is `1.0`.

## One mechanism

For non-chroma mattes, recover a flooded one-pixel edge only when its color
delta is collinear with an adjacent retained foreground pixel. Reconstruct
alpha as the local contrast projection ratio and unmix premultiplied RGB.
Prompt, provider, action registration, output scale, and cost stay unchanged.

## Falsifiable prediction

The targeted light-subject class improves its boundary F1 and foreground
retention; full matte error falls by at least `5%` relative; every other hard
class stays within `-2pp`; effective success remains `>=99%`; field local p95
and estimated unit cost stay within `+10%`.

## Attempt A — rejected

- Targeted light class: `0.926097 → 0.999961`.
- Full matte error reduction: `86.9%`.
- Other synthetic class regression: none over `2pp`.
- Field local p95: within budget.
- Effective field success: `90% → 60%` — hard failure.
- New error: `subject_clipped_left × 4`.

The full regression exposed two applicability failures rather than a bad
projection model: some provider batches use a dark presentation frame, and
some real subjects already touch the crop edge. Recovering either boundary can
resurrect the frame or manufacture clipped pixels.

## Same-mechanism refinement

Keep the local-contrast projection, but apply it only when:

- the estimated matte is light, warm, and neutral;
- no dark presentation line covers at least half of a near-edge row or column;
- the candidate is at least two pixels inside the crop.

The field eval also gained an independent `alphaOccupancy <= 75%` safety gate
so opaque presentation backgrounds fail explicitly as `field_matte_opaque`.

## Final result — accepted locally

- Effective success: `90% → 100%`.
- Matte primary error: `1.4199% → 0.1888%` (`-86.70%` relative).
- Targeted light class: `0.926097 → 0.999961`.
- Other hard-class deltas: `0`; no regression over `2pp`.
- Highest-frequency structural error from Round 001 remains eliminated.
- Field local p95: `31525.2ms → 31409.2ms` (`0.996×`).
- Estimated unit cost: unchanged at `$0.1035`.
- Improvement contact-sheet rows: `12`; regression rows: `0`.

Provider latency was not persisted in the retained Starter Action records, so
the provider-p95 gate is still unavailable. Keep this result on the experiment
branch until fresh instrumented samples unlock the `5% → 25% → 100%` rollout.
