# Round 001 — adaptive transparent-gutter registration

## Fixed baseline

- Dataset: `mimo-diy-v1`
- Commit: `020c94c`
- Effective success: `90%` (`9/10` retained field jobs)
- Matte error: `1.4199%`
- Field local p95: `31.464s`
- Pareto #1: `subject_clipped_right` (`1`)
- Failing case: S3 tennis job `157c3e15-bd60-4a07-8526-593c793cc214`

## Ranked hypotheses

1. **Recoverable registration overflow.** The complete racket exists on the
   1536px canvas but crosses an implied 512px boundary. Fixed-width slicing
   creates the crop. Evidence: the retained batch visibly contains the complete
   racket and a transparent gutter before the next pose.
2. **False clip from matte fringe.** Less likely: the right-edge contact might
   be residual warm matte. Evidence against: the visible racket spans the
   boundary by substantially more than the alpha threshold.
3. **Provider omitted the racket edge.** Evidence against: the missing pixels
   are present on the other side of the artificial boundary.

## One mechanism

For unframed `1×N` action families only, register columns from wide transparent
gutters near the expected separators. If any gutter is ambiguous, retain the
strict fixed-width path and its clipping failure. No prompt, provider, matte,
cost, or runtime animation change is included in this round.

## Falsifiable prediction

The targeted S3 tennis job changes from `subject_clipped_right` to pass with all
nine frames. Full `mimo-diy-v1` effective success rises from `90%` to `100%`;
matte scores and provider cost remain identical; no hard class regresses by
more than two points; field local p95 remains within `+10%`.

## Result

- Targeted retained job: pass (`100%`), zero provider calls.
- Full effective success: `100%` (`+10pp`).
- Pareto #1 reduction: `100%`.
- Matte error: unchanged at `1.4199%`.
- Hard-class regression: `0pp`.
- Field local p95: `31.810s` (`+1.24%`).
- Estimated unit cost: unchanged at `$0.1035`.

The mechanism passes its prediction and all non-matte local gates. It is not
rollout-eligible yet: the separate matte-improvement goal is still open, and
provider p95 telemetry is not persisted. Keep it on the experiment branch while
Round 002 changes only the matte mechanism.
