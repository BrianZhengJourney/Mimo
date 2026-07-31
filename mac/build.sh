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
cp overlay.html settings.html "$APP/Contents/Resources/"
cp AppIcon.icns "$APP/Contents/Resources/"
cp -R assets/style-reference "$APP/Contents/Resources/style-reference"
cp -R assets/motion-reference "$APP/Contents/Resources/motion-reference"
cp -R assets/behavior "$APP/Contents/Resources/behavior"

frameworks=()
for framework in "${APP_FRAMEWORKS[@]}"; do frameworks+=(-framework "$framework"); done

swiftc -module-cache-path "$MODULE_CACHE" -O "${APP_SOURCES[@]}" \
  -o "$APP/Contents/MacOS/$APP_NAME" "${frameworks[@]}"

codesign --force -s "${MIMO_SIGN_IDENTITY:--}" "$APP"
if [ -z "${MIMO_SIGN_IDENTITY:-}" ]; then
  echo "note: ad-hoc signed. Set MIMO_SIGN_IDENTITY to a stable self-signed" \
       "identity to keep Automation and Keychain grants across rebuilds."
fi
echo "built: $PWD/$APP"

# mirror the preview assets for the sandboxed preview server (TCC can't read
# ~/Desktop). Only the HTML the preview actually loads — mirroring the whole
# source tree published every .swift file, including the Keychain code, over
# localhost HTTP.
if [ "${MIMO_SERVE:-0}" = "1" ]; then
  SERVE_DIR=/private/tmp/mimo-serve/mac
  mkdir -p "$SERVE_DIR"
  cp overlay.html settings.html "$SERVE_DIR/"
  echo "preview assets: $SERVE_DIR"
fi
