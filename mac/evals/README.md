# Mimo DIY eval loop

This directory turns DIY quality work into a repeatable, falsifiable loop.
It never calls an image provider.

## Two fixed layers

1. `diy-v3` synthetic matte cases have exact alpha ground truth. They measure
   alpha IoU, boundary F1, foreground retention, background rejection, and a
   weighted matte error rate across S1/S2/S3 classes.
2. Ten retained, current-contract Starter Action jobs are reprocessed from
   their already-paid batches. They measure real effective success, error
   frequency, local p95 latency, and unchanged provider-call cost. The source
   images stay in the user's Application Support directory and are never
   copied into the repository. A processed frame occupying more than `75%` of
   its alpha canvas is rejected as `field_matte_opaque`; this catches a framed
   presentation background that structural strip validation alone misses.
   A stable generation identity pins the job's character, action contract,
   quality, and call count; SHA-256 pins every retained batch. Mutable review
   state and timestamps cannot invalidate unchanged art, while a missing or
   changed provider input still fails closed.

Two `UNKNOWN` field artifacts remain in the triage queue until one root cause
is assigned. `diy-v3` also pins the newly discovered framed S2 and near-edge S3
matte cases. New S2/S3 and UNKNOWN examples must be added to a new versioned
dataset before a round closes.

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

Starter Action records persist the duration and outcome of every newly
submitted provider call. Legacy retained jobs have no timing samples, so the
first instrumented field cohort establishes a fresh provider-p95 baseline.
Candidate rollout remains blocked until both its baseline and candidate have
provider samples and the p95 ratio is at most `1.10`.

For a release audit, `telemetry.sh` runs two interleaved default-action packs
through the exact production `generateStarterActionBatch` path. Results live in
an isolated local directory: they are never installed and never modify a pet or
its Studio jobs. The harness checkpoints after every paid call, performs the
same coherent-batch normalization/QA locally, and writes one validated
`telemetry.json` per cohort. A complete cohort is exactly 10 calls and four
passing action results. Pair order is counterbalanced across the ten calls, so
baseline and candidate each run first five times instead of assigning queue
delay to one role.

```bash
./mac/evals/telemetry.sh \
  --pet-dir /path/to/a/local/Mimo/Pets/UUID \
  --style-board mac/assets/style-reference/mimo-human-style-reference-board.png \
  --style-profile human-v2 \
  --output-root /private/local/telemetry-run \
  --runtime-commit "$(git rev-parse HEAD)" \
  --quality medium \
  --cohort-id initial \
  --preflight true
```

Remove `--preflight true` only after cost approval. A failed checkpoint is not
silently replayed; resume with `--retry-failed true` after reviewing it.
Candidate evaluation consumes the pair without rewriting the fixed baseline:

Use a fresh output root and cohort ID with `--candidate-only true` for each
5% / 25% / 100% observation. This makes every rollout decision consume a new
ten-call candidate pack rather than repeatedly approving the initial evidence.

```bash
MIMO_EVAL_BASELINE_PROVIDER_TELEMETRY=/run/baseline/telemetry.json \
MIMO_EVAL_PROVIDER_TELEMETRY=/run/candidate/telemetry.json \
  ./mac/evals/run.sh candidate-with-provider \
  artifacts/evals/runs/baseline/metrics.json
```

The eval rejects partial cohorts, dirty runtime commits, contract/input/quality
mismatches, call success below 99%, or action QA below 99%.

## Round discipline

Every candidate names one mechanism and one falsifiable prediction. Run a
targeted class first, then the full dataset. Three consecutive rounds improving
effective success by less than `0.2` percentage points stop local tuning and
trigger a model/data/product-strategy review.

Rollout is `5% -> 25% -> 100%`. Any hard-gate failure means immediate rollback
to the last accepted mechanism; no “ship with a note” exception.

## Rollout ledger

Rollout is an executable state machine, not a checklist. It requires clean,
40-character baseline and candidate commits from the same dataset. `start`
enters exactly 5%; passing observations advance to 25%, then 100%, and one
more passing 100% observation marks the candidate complete. Any failed gate,
changed commit, or changed dataset records a rollback to 0%.

```bash
STATE=artifacts/evals/rollouts/diy-v3.json
./mac/evals/rollout.sh start \
  --baseline artifacts/evals/runs/baseline/metrics.json \
  --candidate artifacts/evals/runs/candidate/metrics.json \
  --state "$STATE"
./mac/evals/rollout.sh observe --metrics cohort-5/metrics.json --state "$STATE"
./mac/evals/rollout.sh observe --metrics cohort-25/metrics.json --state "$STATE"
./mac/evals/rollout.sh observe --metrics cohort-100/metrics.json --state "$STATE"
```

`bucket --id <stable-install-id>` deterministically selects the current cohort;
the 5% group is always a subset of 25%. The ledger is the release-control
record; the distribution layer must consult it and may never infer eligibility
from an offline success rate alone.
