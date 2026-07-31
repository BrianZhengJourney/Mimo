# Mimo DIY eval loop

This directory turns DIY quality work into a repeatable, falsifiable loop.
It never calls an image provider.

## Two fixed layers

1. `diy-v1` synthetic matte cases have exact alpha ground truth. They measure
   alpha IoU, boundary F1, foreground retention, background rejection, and a
   weighted matte error rate across S1/S2/S3 classes.
2. Ten retained, current-contract Starter Action jobs are reprocessed from
   their already-paid batches. They measure real effective success, error
   frequency, local p95 latency, and unchanged provider-call cost. The source
   images stay in the user's Application Support directory and are never
   copied into the repository. SHA-256 pins every retained input, so a missing
   or changed field fixture invalidates the run instead of becoming a fake
   product failure.

An additional `UNKNOWN` field artifact remains in the triage queue until one
root cause is assigned. New S2/S3 and UNKNOWN examples must be added to a new
versioned dataset before a round closes.

## Run

```bash
./mac/evals/run.sh baseline
./mac/evals/run.sh candidate artifacts/evals/runs/baseline/metrics.json
```

Run labels are immutable: rerunning an existing label exits instead of
silently mixing artifacts. A run from a dirty worktree records `-dirty` after
the commit SHA.

Each run writes:

- `metrics.json`: aggregate and per-class metrics, error Pareto, gates.
- `cases.json`: case-level scores and error classes.
- `matte-contact-sheet.png`: source / extracted alpha / error heatmap for the
  worst synthetic cases.
- `field-contact-sheet.png`: zero-call real reprocessing results.
- candidate runs also write `improvements-contact-sheet.png` and
  `regressions-contact-sheet.png`.

## Hard gates

- effective success rate `>= 99%`;
- the baseline Pareto #1 error count reduced by `>= 50%`;
- matte primary error rate falls by `>= 5%` relative;
- no S1/S2/S3 class score regresses by more than `2` percentage points;
- local p95 latency and estimated provider cost grow by no more than `10%`.

Provider latency is not currently persisted on Starter Action job records.
Until that telemetry exists, a candidate can pass the local-latency gate but
cannot be promoted to 100% on the full end-to-end latency claim.

## Round discipline

Every candidate names one mechanism and one falsifiable prediction. Run a
targeted class first, then the full dataset. Three consecutive rounds improving
effective success by less than `0.2` percentage points stop local tuning and
trigger a model/data/product-strategy review.

Rollout is `5% -> 25% -> 100%`. Any hard-gate failure means immediate rollback
to the last accepted mechanism; no “ship with a note” exception.
