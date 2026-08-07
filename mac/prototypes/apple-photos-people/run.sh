#!/bin/bash
# One-command launcher for the throwaway Apple Photos prototype.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MAC_ROOT="$(cd "$HERE/../.." && pwd)"
SOURCE_APP="$MAC_ROOT/build/Mimo.app"
PROTOTYPE_APP="/private/tmp/MimoPhotosPeoplePrototype.app"

"$MAC_ROOT/build.sh"
rm -rf "$PROTOTYPE_APP"
ditto "$SOURCE_APP" "$PROTOTYPE_APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.brianzheng.mimo.photos-prototype" "$PROTOTYPE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Mimo Photos Prototype" "$PROTOTYPE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Mimo Photos Prototype" "$PROTOTYPE_APP/Contents/Info.plist"
codesign --force -s - "$PROTOTYPE_APP"
open -n "$PROTOTYPE_APP" --args --photos-people-prototype
