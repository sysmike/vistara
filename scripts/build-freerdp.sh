#!/bin/bash
#
# Builds the pinned FreeRDP release (libfreerdp, libfreerdp-client, WinPR) and
# its one external dependency, OpenSSL, into a self-contained prefix that the
# app bundles.
#
# Pins:
#   FREERDP_VERSION          "<version> <sha256 of the release tarball>"
#   scripts/OPENSSL_VERSION  "<version> <sha256 of the release tarball>"
#
# Usage: scripts/build-freerdp.sh [--force] [--print-key]
#
# Environment:
#   VISTARA_ARCHS       target architectures (default: "arm64 x86_64"). With
#                       more than one, each is built in a work directory of
#                       its own and the libraries are joined with lipo.
#   VISTARA_ARCH        one architecture, as VISTARA_ARCHS with one entry
#   VISTARA_BUILD_DIR   work directory (default: <repo>/build/freerdp)
#
# Output: $VISTARA_BUILD_DIR/prefix/{include,lib}

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHS="${VISTARA_ARCHS:-${VISTARA_ARCH:-arm64 x86_64}}"
read -r -a ARCH_LIST <<<"$ARCHS"
ARCH="${ARCH_LIST[0]}"
DEPLOYMENT_TARGET="14.0"
WORK="${VISTARA_BUILD_DIR:-$ROOT/build/freerdp}"
PREFIX="$WORK/prefix"
STAMP="$PREFIX/.vistara-build-key"

read -r FREERDP_VERSION FREERDP_SHA256 <"$ROOT/FREERDP_VERSION"
read -r OPENSSL_VERSION OPENSSL_SHA256 <"$ROOT/scripts/OPENSSL_VERSION"

FREERDP_URL="https://github.com/FreeRDP/FreeRDP/releases/download/$FREERDP_VERSION/freerdp-$FREERDP_VERSION.tar.gz"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Everything that changes the result: both pins, the architectures, this script.
BUILD_KEY="$(printf '%s\n' "$FREERDP_VERSION" "$FREERDP_SHA256" "$OPENSSL_VERSION" "$OPENSSL_SHA256" \
  "${ARCH_LIST[*]}" "$(sha256 "${BASH_SOURCE[0]}")" | shasum -a 256 | cut -d' ' -f1)"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --print-key) echo "$BUILD_KEY"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '\n==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "this script builds for macOS and must run on macOS"
for tool in cmake curl shasum tar make install_name_tool otool lipo xcrun; do
  command -v "$tool" >/dev/null || die "missing required tool: $tool"
done

if [[ $FORCE -eq 0 && -f "$STAMP" && "$(cat "$STAMP")" == "$BUILD_KEY" ]]; then
  echo "FreeRDP $FREERDP_VERSION (${ARCH_LIST[*]}) is up to date in $PREFIX"
  exit 0
fi

# ---------------------------------------------------------------------------
# Several architectures: build each on its own, then join the libraries.
if [[ ${#ARCH_LIST[@]} -gt 1 ]]; then
  sub_args=()
  [[ $FORCE -eq 1 ]] && sub_args+=(--force)
  for arch in "${ARCH_LIST[@]}"; do
    log "Building for $arch"
    start=$SECONDS
    VISTARA_ARCHS="$arch" VISTARA_BUILD_DIR="$WORK/$arch" "${BASH_SOURCE[0]}" ${sub_args[@]+"${sub_args[@]}"}
    echo "Built $arch in $((SECONDS - start)) s"
  done

  log "Joining ${ARCH_LIST[*]} into $PREFIX"
  first="$WORK/${ARCH_LIST[0]}/prefix"
  # The shim compiles against one set of headers for every slice, so the
  # headers must not differ between architectures.
  for arch in "${ARCH_LIST[@]:1}"; do
    diff -r "$first/include" "$WORK/$arch/prefix/include" ||
      die "the installed headers differ between ${ARCH_LIST[0]} and $arch"
  done
  rm -rf "$PREFIX"
  cp -R "$first" "$PREFIX"
  rm -f "$PREFIX/.vistara-build-key"
  while IFS= read -r lib; do
    name="${lib#"$first/"}"
    slices=()
    for arch in "${ARCH_LIST[@]}"; do slices+=("$WORK/$arch/prefix/$name"); done
    lipo -create "${slices[@]}" -output "$PREFIX/$name"
  done < <(find "$first/lib" -maxdepth 1 -type f -name '*.dylib')

  status=0
  while IFS= read -r lib; do
    archs="$(lipo -archs "$lib")"
    for arch in "${ARCH_LIST[@]}"; do
      [[ " $archs " == *" $arch "* ]] || { echo "$lib: expected $arch, found $archs" >&2; status=1; }
    done
  done < <(find "$PREFIX/lib" -maxdepth 1 -type f -name '*.dylib')
  [[ $status -eq 0 ]] || die "verification failed"
  for arch in "${ARCH_LIST[@]}"; do
    echo "$arch slice: $(du -sk "$WORK/$arch/prefix/lib" | cut -f1) KiB of libraries"
  done
  echo "universal: $(du -sk "$PREFIX/lib" | cut -f1) KiB of libraries"

  echo "$BUILD_KEY" >"$STAMP"
  log "Done: FreeRDP $FREERDP_VERSION with OpenSSL $OPENSSL_VERSION (${ARCH_LIST[*]}) in $PREFIX"
  exit 0
fi

JOBS="$(sysctl -n hw.ncpu)"
GENERATOR=()
if command -v ninja >/dev/null; then GENERATOR=(-G Ninja); fi

rm -rf "$PREFIX" "$WORK/src" "$WORK/obj"
mkdir -p "$PREFIX" "$WORK/src" "$WORK/obj" "$WORK/downloads"

# fetch <url> <sha256> <destination directory>
fetch() {
  local url="$1" expected="$2" dest="$3" archive actual
  archive="$WORK/downloads/$(basename "$url")"
  if [[ ! -f "$archive" || "$(sha256 "$archive")" != "$expected" ]]; then
    curl --fail --location --silent --show-error --retry 3 --proto '=https' --output "$archive" "$url"
  fi
  actual="$(sha256 "$archive")"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$archive"
    die "checksum mismatch for $url: expected $expected, got $actual"
  fi
  mkdir -p "$dest"
  tar -xzf "$archive" -C "$dest" --strip-components 1
}

# Keep Homebrew and MacPorts out of the build: nothing they provide may leak in.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

# ---------------------------------------------------------------------------
log "OpenSSL $OPENSSL_VERSION ($ARCH)"
fetch "$OPENSSL_URL" "$OPENSSL_SHA256" "$WORK/src/openssl"
(
  cd "$WORK/src/openssl"
  # --openssldir points at a directory no user can write to, so a bundled
  # OpenSSL never reads an openssl.cnf or CA files from a path baked in at
  # build time. no-module keeps all providers inside libcrypto: there is no
  # modules directory to ship.
  ./Configure "darwin64-$ARCH-cc" shared no-tests no-docs no-apps no-module no-engine \
    --prefix="$PREFIX" --libdir=lib --openssldir=/var/empty \
    "-mmacosx-version-min=$DEPLOYMENT_TARGET"
  make -j"$JOBS" build_sw
  make install_sw
)

# OpenSSL records absolute install names. Make them relative before FreeRDP
# links against them, so FreeRDP's libraries record @rpath references.
chmod u+w "$PREFIX"/lib/libssl.3.dylib "$PREFIX"/lib/libcrypto.3.dylib
install_name_tool -id @rpath/libcrypto.3.dylib "$PREFIX/lib/libcrypto.3.dylib"
install_name_tool -id @rpath/libssl.3.dylib \
  -change "$PREFIX/lib/libcrypto.3.dylib" @rpath/libcrypto.3.dylib \
  "$PREFIX/lib/libssl.3.dylib"

# ---------------------------------------------------------------------------
log "FreeRDP $FREERDP_VERSION ($ARCH)"
fetch "$FREERDP_URL" "$FREERDP_SHA256" "$WORK/src/freerdp"

# Channels Vistara does not use in version 1. Fewer parsers of untrusted
# server data means less attack surface. Kept: cliprdr, disp, drdynvc, drive,
# rdpdr, rdpgfx, rdpsnd, and the small input and graphics helpers.
DISABLED_CHANNELS=(AUDIN LOCATION PARALLEL PRINTER RDP2TCP RDPEAR RDPECAM REMDESK SERIAL SMARTCARD SSHAGENT TSMF URBDRC)
CHANNEL_FLAGS=()
for channel in "${DISABLED_CHANNELS[@]}"; do CHANNEL_FLAGS+=("-DCHANNEL_$channel=OFF"); done

# FreeRDP picks its target from CMAKE_SYSTEM_PROCESSOR, which is the host's
# unless cross compiling: building x86_64 on Apple silicon must say so.
CROSS_FLAGS=()
if [[ "$ARCH" != "$(uname -m)" ]]; then
  CROSS_FLAGS=(-DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR="$ARCH")
fi

cmake -S "$WORK/src/freerdp" -B "$WORK/obj/freerdp" ${GENERATOR[@]+"${GENERATOR[@]}"} \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local" \
  -DOPENSSL_ROOT_DIR="$PREFIX" \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_TESTING=OFF \
  -DWITH_CLIENT_COMMON=ON \
  -DWITH_CLIENT=OFF \
  -DWITH_SERVER=OFF \
  -DWITH_SAMPLE=OFF \
  -DWITH_X11=OFF \
  -DWITH_MANPAGES=OFF \
  -DWITH_WINPR_TOOLS=OFF \
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
  -DWITH_MACAUDIO=ON \
  -DWITH_INTERNAL_MD4=ON \
  -DWITH_INTERNAL_MD5=ON \
  -DWITH_INTERNAL_RC4=ON \
  "${CHANNEL_FLAGS[@]}" ${CROSS_FLAGS[@]+"${CROSS_FLAGS[@]}"}
cmake --build "$WORK/obj/freerdp" --parallel "$JOBS"
cmake --install "$WORK/obj/freerdp"

# ---------------------------------------------------------------------------
log "Verifying $PREFIX"
status=0
for name in freerdp3 freerdp-client3 winpr3 ssl crypto; do
  compgen -G "$PREFIX/lib/lib$name.*dylib" >/dev/null || { echo "missing library: lib$name" >&2; status=1; }
done
while IFS= read -r lib; do
  archs="$(lipo -archs "$lib")"
  [[ " $archs " == *" $ARCH "* ]] || { echo "$lib: expected $ARCH, found $archs" >&2; status=1; }
  # First line of `otool -L` is the file name, the second its own install name.
  while IFS= read -r dep; do
    case "$dep" in
      @rpath/* | /usr/lib/* | /System/Library/*) ;;
      *) echo "$lib: non-relocatable reference: $dep" >&2; status=1 ;;
    esac
  done < <(otool -L "$lib" | tail -n +2 | awk '{print $1}')
done < <(find "$PREFIX/lib" -maxdepth 1 -type f -name '*.dylib')
[[ -f "$PREFIX/include/freerdp3/freerdp/freerdp.h" ]] || { echo "missing FreeRDP headers" >&2; status=1; }
grep -q "FREERDP_VERSION_FULL \"$FREERDP_VERSION\"" "$PREFIX/include/freerdp3/freerdp/version.h" ||
  { echo "installed headers do not report version $FREERDP_VERSION" >&2; status=1; }
[[ $status -eq 0 ]] || die "verification failed"

echo "$BUILD_KEY" >"$STAMP"
log "Done: FreeRDP $FREERDP_VERSION with OpenSSL $OPENSSL_VERSION ($ARCH) in $PREFIX"
