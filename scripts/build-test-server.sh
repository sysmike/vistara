#!/bin/bash
#
# Builds FreeRDP's shadow server from the pinned source, for integration
# tests only. It is never bundled in the app.
#
# The server's "sample" screen source has no monitor; a patch gives it one
# fixed 1024x768 monitor so clients receive a framebuffer of a known size.
#
# Requires scripts/build-freerdp.sh to have run (for OpenSSL).
#
# Usage: scripts/build-test-server.sh [--force] [--print-key]
# Output: build/test-server/prefix/bin/{freerdp-shadow-cli,winpr-hash}

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${VISTARA_ARCH:-arm64}"
DEPLOYMENT_TARGET="14.0"
DEPS="${VISTARA_BUILD_DIR:-$ROOT/build/freerdp}/prefix"
WORK="$ROOT/build/test-server"
PREFIX="$WORK/prefix"
STAMP="$PREFIX/.vistara-build-key"
PATCH="$ROOT/scripts/test-server/sample-screen.patch"

read -r FREERDP_VERSION FREERDP_SHA256 <"$ROOT/FREERDP_VERSION"
FREERDP_URL="https://github.com/FreeRDP/FreeRDP/releases/download/$FREERDP_VERSION/freerdp-$FREERDP_VERSION.tar.gz"

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
die() { echo "error: $*" >&2; exit 1; }

BUILD_KEY="$(printf '%s\n' "$FREERDP_SHA256" "$ARCH" "$(sha256 "${BASH_SOURCE[0]}")" "$(sha256 "$PATCH")" \
  "$("$ROOT/scripts/build-freerdp.sh" --print-key)" | shasum -a 256 | cut -d' ' -f1)"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --print-key) echo "$BUILD_KEY"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ $FORCE -eq 0 && -f "$STAMP" && "$(cat "$STAMP")" == "$BUILD_KEY" ]]; then
  echo "Test server for FreeRDP $FREERDP_VERSION is up to date in $PREFIX"
  exit 0
fi
[[ -f "$DEPS/lib/libssl.3.dylib" ]] || die "OpenSSL not found in $DEPS. Run scripts/build-freerdp.sh first."

GENERATOR=()
if command -v ninja >/dev/null; then GENERATOR=(-G Ninja); fi

rm -rf "$PREFIX" "$WORK/src" "$WORK/obj"
mkdir -p "$PREFIX/lib" "$WORK/src" "$WORK/obj" "$WORK/downloads"

archive="$WORK/downloads/freerdp-$FREERDP_VERSION.tar.gz"
if [[ ! -f "$archive" || "$(sha256 "$archive")" != "$FREERDP_SHA256" ]]; then
  curl --fail --location --silent --show-error --retry 3 --proto '=https' --output "$archive" "$FREERDP_URL"
fi
[[ "$(sha256 "$archive")" == "$FREERDP_SHA256" ]] || { rm -f "$archive"; die "checksum mismatch for $FREERDP_URL"; }
tar -xzf "$archive" -C "$WORK/src" --strip-components 1
patch -d "$WORK/src" -p1 <"$PATCH"

export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
unset PKG_CONFIG_PATH
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

cmake -S "$WORK/src" -B "$WORK/obj" ${GENERATOR[@]+"${GENERATOR[@]}"} \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_PREFIX_PATH="$DEPS" \
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local" \
  -DOPENSSL_ROOT_DIR="$DEPS" \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_TESTING=OFF \
  -DWITH_SERVER=ON \
  -DWITH_SHADOW=ON \
  -DWITH_SHADOW_SUBSYSTEM=OFF \
  -DWITH_PROXY=OFF \
  -DWITH_PLATFORM_SERVER=OFF \
  -DWITH_WINPR_TOOLS=ON \
  -DWITH_CLIENT=OFF \
  -DWITH_SAMPLE=OFF \
  -DWITH_X11=OFF \
  -DWITH_MANPAGES=OFF \
  -DWITH_FFMPEG=OFF \
  -DWITH_SWSCALE=OFF \
  -DWITH_CAIRO=OFF \
  -DWITH_OPUS=OFF \
  -DWITH_KRB5=OFF \
  -DWITH_PKCS11=OFF \
  -DWITH_JSON_DISABLED=ON \
  -DWITH_AAD=OFF \
  -DWITH_URIPARSER=OFF \
  -DWITH_CUPS=OFF \
  -DWITH_FUSE=OFF \
  -DWITH_INTERNAL_MD4=ON \
  -DWITH_INTERNAL_MD5=ON \
  -DWITH_INTERNAL_RC4=ON
cmake --build "$WORK/obj" --parallel "$(sysctl -n hw.ncpu)"
cmake --install "$WORK/obj"

# The binaries find FreeRDP through @loader_path/../lib; put OpenSSL there too.
cp -f "$DEPS/lib/libssl.3.dylib" "$DEPS/lib/libcrypto.3.dylib" "$PREFIX/lib/"

ls "$PREFIX/bin"
for tool in freerdp-shadow-cli winpr-hash; do
  [[ -x "$PREFIX/bin/$tool" ]] || die "expected $tool in $PREFIX/bin"
done
"$PREFIX/bin/freerdp-shadow-cli" /version

echo "$BUILD_KEY" >"$STAMP"
echo "Done: test server in $PREFIX"
