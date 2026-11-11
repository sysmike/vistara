#!/bin/bash
#
# Xcode build phase: copies the FreeRDP and OpenSSL libraries into the app's
# Frameworks folder and signs them with the app's identity. The app is signed
# after this phase, which seals the copies.

set -euo pipefail

PREFIX="$SRCROOT/build/freerdp/prefix"
DEST="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"

if [[ ! -d "$PREFIX/lib" ]]; then
  echo "error: FreeRDP is not built. Run scripts/build-freerdp.sh first." >&2
  exit 1
fi

mkdir -p "$DEST"
# The names the libraries are loaded by (their install names).
for name in libfreerdp-client3.3 libfreerdp3.3 libwinpr3.3 libssl.3 libcrypto.3; do
  cp -fL "$PREFIX/lib/$name.dylib" "$DEST/$name.dylib"
  chmod u+w "$DEST/$name.dylib"
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$DEST/$name.dylib"
done
