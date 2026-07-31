#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."
source ./mac/common.sh

LABEL="${1:-baseline}"
BASELINE="${2:-}"
DATASET="${MIMO_EVAL_DATASET:-mac/evals/datasets/diy-v2.json}"
HISTORY_ROOT="${MIMO_EVAL_HISTORY_ROOT:-$(cd "$HOME/Library/Application Support" && pwd)/Mimo}"
OUTPUT_ROOT="${MIMO_EVAL_OUTPUT_ROOT:-artifacts/evals/runs}"
OUTPUT="$OUTPUT_ROOT/$LABEL"
BINARY="${TMPDIR:-/private/tmp}/mimo-diy-eval"
COMMIT="$(git rev-parse HEAD)"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  COMMIT="$COMMIT-dirty"
fi

if [ -e "$OUTPUT/metrics.json" ]; then
  echo "eval label already exists: $LABEL" >&2
  echo "choose a new immutable label instead of overwriting a run" >&2
  exit 2
fi

mkdir -p "$OUTPUT" "$MODULE_CACHE"

frameworks=()
for framework in "${APP_FRAMEWORKS[@]}"; do frameworks+=(-framework "$framework"); done

swiftc -module-cache-path "$MODULE_CACHE" \
  mac/starter_action.swift \
  mac/custom_pet.swift \
  mac/character_sheet.swift \
  mac/action_sheet.swift \
  mac/action_generation_job.swift \
  mac/evals/diy_eval.swift \
  -o "$BINARY" "${frameworks[@]}"

args=(
  --dataset "$DATASET"
  --history-root "$HISTORY_ROOT"
  --output "$OUTPUT"
  --label "$LABEL"
  --commit "$COMMIT"
)
if [ -n "$BASELINE" ]; then args+=(--baseline "$BASELINE"); fi

"$BINARY" "${args[@]}"
echo "eval artifacts: $PWD/$OUTPUT"
