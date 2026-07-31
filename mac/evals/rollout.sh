#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."
source ./mac/common.sh

BINARY="${TMPDIR:-/private/tmp}/mimo-diy-rollout"
swiftc -module-cache-path "$MODULE_CACHE" \
  mac/evals/diy_rollout.swift \
  mac/evals/diy_rollout_cli.swift \
  -o "$BINARY"

"$BINARY" "$@"

