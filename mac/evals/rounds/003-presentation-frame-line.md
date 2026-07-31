# Round 003 — near-edge presentation-frame line removal

## Fixed baseline

`baseline-v3-36d8f99`

- Effective success: `87.5%`.
- Matte primary error: `1.5792%`.
- Field success: `100%`.
- Pareto #1: `matte_framed_light_subject_warm_matte × 20`.
- Framed-class score: `0.895059`.
- Near-edge S3 score: `0.989933`.

## Ranked hypotheses

1. **A long, dark near-edge presentation rule survives as foreground.**
   Background rejection remains high (`0.9971`), but the extra rule creates a
   second false boundary and drops boundary F1 to about `0.748`.
2. **Warm-matte recovery damages the pale subject.** Disfavored: the existing
   dark-frame guard disables local recovery for this class.
3. **The fixture matte estimate is unstable.** Disfavored: foreground
   retention stays about `0.956`, matching the known guarded warm-matte path.

## One mechanism

Detect only a contiguous dark run covering at least half of a row or column
within 16 pixels of the crop edge, and classify that run as presentation
background. Short dark details remain untouched. No prompt, provider,
registration, scale, or cost changes.

## Falsifiable prediction

- Framed-class score rises above `0.90` and all 20 cases pass.
- Pareto #1 count falls by at least `50%`.
- Effective success reaches at least `99%`.
- Every existing hard class stays within `-2pp`.
- Field local p95 and unit cost stay within `+10%`.

## Guard refinement

The first targeted unit run exposed a safety regression: a dark subject
touching the physical source edge could also span half a row/column and be
mistaken for a rule. The candidate was stopped before full eval. The same
line-classification mechanism now requires no broad dark support four pixels
to either side; thick subjects stay intact and continue to fail crop QA.

## Final result — accepted locally

- Effective success: `87.5% → 100%`.
- Pareto #1 count: `20 → 0` (`-100%`).
- Framed-class score: `0.895059 → 0.926112` (`+3.1053pp`).
- Matte primary error: `1.5792% → 1.1910%` (`-24.58%` relative).
- Other hard-class deltas: `0`; no regression over `2pp`.
- Field success: `100%`.
- Field local p95 ratio: `1.0116×`.
- Estimated unit cost ratio: `1.0×`.
- Improvement contact-sheet rows: `12`; regression rows: `0`.

Provider p95 remains unavailable for the legacy retained cohort, so the
end-to-end hard gate and `5% → 25% → 100%` promotion remain blocked pending
fresh instrumented action calls.

## Clean-head replay and rollout audit

The original candidate artifact was generated while the one-mechanism change
was still uncommitted, so it records `-dirty` and is evidence for the local
decision only. The same full dataset was replayed without provider calls at
clean release head `b2245e4` as `round-003-clean-b2245e4`:

- effective success `100%`, matte error `1.1910%`, Pareto empty;
- no hard-class regressions and no regression contact-sheet rows;
- field local p95 `30,196.4ms` (lower than the original candidate run);
- provider samples `0`.

The executable rollout ledger correctly refused to enter 5% and recorded
`providerP95LatencyAvailable`, `providerP95LatencyWithin10Percent`, and
`rolloutEligible` as failed. No rollout occurred.
