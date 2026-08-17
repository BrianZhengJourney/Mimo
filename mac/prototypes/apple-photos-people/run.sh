#!/bin/bash
# One-command launcher for the throwaway Apple Photos prototype.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MAC_ROOT="$(cd "$HERE/../.." && pwd)"
SOURCE_APP="$MAC_ROOT/build/Mimo.app"
# Keep the prototype in the workspace build directory. LaunchServices and TCC
# do not reliably register app bundles from /private/tmp, which made Photos
# permission disappear after an ad-hoc rebuild.
PROTOTYPE_APP="$MAC_ROOT/build/Mimo Photos Prototype.app"
source "$MAC_ROOT/face_models.sh"
MODEL_DIR="$(cd "$MAC_ROOT" && mimo_face_model_dir)"

"$MAC_ROOT/build.sh"
rm -rf "$PROTOTYPE_APP"
ditto "$SOURCE_APP" "$PROTOTYPE_APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.brianzheng.mimo.photos-prototype" "$PROTOTYPE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Mimo Photos Prototype" "$PROTOTYPE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Mimo Photos Prototype" "$PROTOTYPE_APP/Contents/Info.plist"
models=(MimoAdaFaceIR101)
for argument in "$@"; do
  if [[ "$argument" == "--photos-people-model-lab" ]]; then
    models+=(MimoAdaFaceKPRPE)
  fi
done
for model in "${models[@]}"; do
  if mimo_compiled_face_model_is_valid "$MODEL_DIR/$model.mlmodelc"; then
    ditto "$MODEL_DIR/$model.mlmodelc" "$PROTOTYPE_APP/Contents/Resources/$model.mlmodelc"
  fi
done
codesign --force -s - "$PROTOTYPE_APP"
open -n "$PROTOTYPE_APP" --args --photos-people-prototype --photos-people-standalone "$@"
