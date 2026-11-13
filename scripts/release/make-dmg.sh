#!/bin/bash
#
# Packs the app into a compressed DMG with a link to Applications, signs the
# DMG when an identity is given, and writes SHA-256 checksums.
#
# Environment: VISTARA_SIGN_IDENTITY, VISTARA_VERSION, VISTARA_RELEASE_DIR,
# as for build-app.sh.
#
# Output: $VISTARA_RELEASE_DIR/Vistara-<version>.dmg and SHA256SUMS

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IDENTITY="${VISTARA_SIGN_IDENTITY:--}"
OUT="${VISTARA_RELEASE_DIR:-$ROOT/build/release}"
VERSION="${VISTARA_VERSION:-0.0.0}"
dmg="$OUT/Vistara-$VERSION.dmg"

stage="$OUT/dmg"
rm -rf "$stage" "$dmg"
mkdir -p "$stage"
cp -R "$OUT/Vistara.app" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Vistara $VERSION" -srcfolder "$stage" -ov -format UDZO "$dmg"
rm -rf "$stage"

if [[ "$IDENTITY" != "-" ]]; then
  codesign --sign "$IDENTITY" --timestamp "$dmg"
  codesign --verify --verbose=2 "$dmg"
fi
echo "$dmg"
