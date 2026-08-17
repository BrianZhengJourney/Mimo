#!/bin/bash
# Shared local Core ML model discovery and integrity checks.

mimo_compiled_face_model_is_valid() {
  local model_dir="$1"
  [ -d "$model_dir" ] && [ -s "$model_dir/coremldata.bin" ]
}

mimo_face_model_dir() {
  if [ -n "${MIMO_FACE_MODEL_DIR:-}" ]; then
    printf '%s\n' "$MIMO_FACE_MODEL_DIR"
    return
  fi

  local persistent_dir="$PWD/.local/face-models"
  local legacy_dir="/private/tmp/mimo-face-compiled"
  if mimo_compiled_face_model_is_valid \
      "$persistent_dir/MimoAdaFaceIR101.mlmodelc"; then
    printf '%s\n' "$persistent_dir"
  elif mimo_compiled_face_model_is_valid \
      "$legacy_dir/MimoAdaFaceIR101.mlmodelc"; then
    # One compatibility bridge for existing developer machines. New setup
    # always writes to the persistent workspace-local directory above.
    printf '%s\n' "$legacy_dir"
  else
    printf '%s\n' "$persistent_dir"
  fi
}
