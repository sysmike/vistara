#!/bin/bash
#
# Builds the universal Release app and signs it, then checks the signature.
#
# Environment:
#   VISTARA_SIGN_IDENTITY   "Developer ID Application: …" or its hash; "-"
#                           (the default) signs ad hoc, for a dry run
#   VISTARA_TEAM_ID         the Developer ID team; required when signing
#   VISTARA_VERSION         marketing version, for example 0.1.0
#   VISTARA_BUILD_NUMBER    build number (default 1)
#   VISTARA_RELEASE_DIR     output directory (default build/release)
#
# Output: $VISTARA_RELEASE_DIR/Vistara.app

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IDENTITY="${VISTARA_SIGN_IDENTITY:--}"
OUT="${VISTARA_RELEASE_DIR:-$ROOT/build/release}"
VERSION="${VISTARA_VERSION:-0.0.0}"
BUILD_NUMBER="${VISTARA_BUILD_NUMBER:-1}"

die() { echo "error: $*" >&2; exit 1; }

settings=(
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
)
if [[ "$IDENTITY" != "-" ]]; then
  [[ -n "${VISTARA_TEAM_ID:-}" ]] || die "VISTARA_TEAM_ID is required when signing"
  # The embed phase signs the libraries with the same identity, with a
  # secure timestamp and the hardened runtime (scripts/embed-freerdp.sh).
  settings+=(
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$VISTARA_TEAM_ID"
    OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
  )
fi

cd "$ROOT"
xcodebuild build -project Vistara.xcodeproj -scheme Vistara -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$OUT/DerivedData" "${settings[@]}"

rm -rf "$OUT/Vistara.app"
cp -R "$OUT/DerivedData/Build/Products/Release/Vistara.app" "$OUT/Vistara.app"
app="$OUT/Vistara.app"

echo "==> Checking $app"
codesign --verify --deep --strict --verbose=2 "$app"

status=0
for binary in "$app/Contents/MacOS/Vistara" "$app"/Contents/Frameworks/*.dylib; do
  archs="$(lipo -archs "$binary")"
  echo "$(basename "$binary"): $archs"
  [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || { echo "  missing a slice" >&2; status=1; }
done

# No hardened runtime exceptions (docs/ARCHITECTURE.md, Security posture).
entitlements="$(codesign --display --entitlements - --xml "$app" 2>/dev/null)"
if grep -q "com.apple.security.cs." <<<"$entitlements"; then
  echo "error: the app has a hardened runtime exception:" >&2
  grep -o "com.apple.security.cs.[a-z.-]*" <<<"$entitlements" >&2
  status=1
fi
grep -q "com.apple.security.app-sandbox" <<<"$entitlements" || { echo "error: not sandboxed" >&2; status=1; }

if [[ "$IDENTITY" != "-" ]]; then
  details="$(codesign --display --verbose=4 "$app" 2>&1)"
  grep -Eq "flags=0x[0-9a-f]*\(runtime\)" <<<"$details" || { echo "error: no hardened runtime" >&2; status=1; }
  grep -q "^Authority=Developer ID Application" <<<"$details" || { echo "error: not Developer ID" >&2; status=1; }
  grep -q "^Timestamp=" <<<"$details" || { echo "error: no secure timestamp" >&2; status=1; }
  # Library validation loads only libraries signed by the app's own team.
  for lib in "$app"/Contents/Frameworks/*.dylib; do
    team="$(codesign --display --verbose=4 "$lib" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [[ "$team" == "$VISTARA_TEAM_ID" ]] || { echo "error: $(basename "$lib") is signed by team '$team'" >&2; status=1; }
  done
fi

[[ $status -eq 0 ]] || die "the app failed its checks"
echo "==> $app is ready ($(du -sh "$app" | cut -f1))"
