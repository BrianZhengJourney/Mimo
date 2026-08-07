#!/bin/bash
# Build Mimo.app — no Xcode project needed, just swiftc.
#
# MIMO_SIGN_IDENTITY: name of a self-signed certificate in the login keychain.
#   Ad-hoc signing (the default when unset) mints a fresh identity every build,
#   so macOS treats each rebuild as a different app: browser Automation
#   prompts come back and the Keychain ACL on the stored API key breaks. Set
#   this to a stable identity to keep both across rebuilds.
# MIMO_SERVE=1: mirror the preview HTML into /private/tmp for the sandboxed
#   preview server.
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh

APP="build/$APP_NAME.app"
# clear the whole build dir, not just this bundle — the pre-rename bundle used
# to linger here indefinitely, easy to launch by mistake
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$MODULE_CACHE"

cp Info.plist "$APP/Contents/"
cp overlay.html settings.html reflection.html "$APP/Contents/Resources/"
cp AppIcon.icns "$APP/Contents/Resources/"
cp -R assets/style-reference "$APP/Contents/Resources/style-reference"
cp -R assets/motion-reference "$APP/Contents/Resources/motion-reference"
cp -R assets/behavior "$APP/Contents/Resources/behavior"

# Stamp the exact source state into the bundle. This is intentionally generated
# at build time (never checked in), so the running app can make stale builds
# obvious without shelling out or assuming the repository is still present.
BUILD_COMMIT="$(git rev-parse --short=8 HEAD 2>/dev/null || echo unknown)"
if git diff --quiet --ignore-submodules HEAD -- 2>/dev/null; then
  BUILD_DIRTY=false
else
  BUILD_DIRTY=true
fi
BUILD_MARKER=""
if [ "$BUILD_DIRTY" = true ]; then BUILD_MARKER="*"; fi

# Prefer an explicitly scoped identity, then a previously-created local Mimo
# identity. Creating that certificate is a one-time user-authorized setup; the
# build never mutates Keychain on its own.
SIGN_IDENTITY="${MIMO_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null \
     | grep -Fq '"Mimo Local Development"'; then
  SIGN_IDENTITY="Mimo Local Development"
fi
SIGN_MODE=temporary
if [ -n "$SIGN_IDENTITY" ]; then SIGN_MODE=stable; fi
/usr/libexec/PlistBuddy -c "Add :MimoBuildCommit string $BUILD_COMMIT" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :MimoBuildDirty bool $BUILD_DIRTY" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :MimoBuildSignature string $SIGN_MODE" "$APP/Contents/Info.plist"

frameworks=()
for framework in "${APP_FRAMEWORKS[@]}"; do frameworks+=(-framework "$framework"); done

swiftc -module-cache-path "$MODULE_CACHE" -O "${APP_SOURCES[@]}" \
  -o "$APP/Contents/MacOS/$APP_NAME" "${frameworks[@]}"

codesign --force -s "${SIGN_IDENTITY:--}" "$APP"
if [ -z "$SIGN_IDENTITY" ]; then
  echo "note: ad-hoc signed. Set MIMO_SIGN_IDENTITY to a stable self-signed" \
       "identity to keep Automation and Keychain grants across rebuilds."
fi
echo "built: $PWD/$APP · $BUILD_COMMIT$BUILD_MARKER · $SIGN_MODE signature"

# mirror the preview assets for the sandboxed preview server (TCC can't read
# ~/Desktop). Only the HTML the preview actually loads — mirroring the whole
# source tree published every .swift file, including the Keychain code, over
# localhost HTTP.
if [ "${MIMO_SERVE:-0}" = "1" ]; then
  SERVE_DIR=/private/tmp/mimo-serve/mac
  mkdir -p "$SERVE_DIR"
  cp overlay.html settings.html reflection.html "$SERVE_DIR/"
  echo "preview assets: $SERVE_DIR"
fi
