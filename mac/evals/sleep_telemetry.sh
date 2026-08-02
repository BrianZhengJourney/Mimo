#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."
source ./mac/common.sh

BINARY="${TMPDIR:-/private/tmp}/mimo-sleep-safe-zone-telemetry"
sources=(
  mac/starter_action.swift
  mac/pet_provider.swift
  mac/custom_pet.swift
  mac/character_sheet.swift
  mac/action_sheet.swift
  mac/style_reference.swift
  mac/reference_preprocessor.swift
  mac/pet_generation.swift
  mac/evals/sleep_safe_zone_telemetry.swift
  mac/evals/sleep_safe_zone_telemetry_live.swift
)
frameworks=()
for framework in "${APP_FRAMEWORKS[@]}"; do frameworks+=(-framework "$framework"); done

swiftc -module-cache-path "$MODULE_CACHE" "${sources[@]}" \
  -o "$BINARY" "${frameworks[@]}"
"$BINARY" "$@"
