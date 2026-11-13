#!/bin/bash
#
# Builds rdpgw, an open-source RD Gateway (Apache-2.0), from the pinned source,
# for integration tests only. It is never bundled in the app.
#
# rdpgw is two programs: the gateway, and an authentication helper that holds
# the users and answers the gateway's NTLM questions over a local socket.
#
# Requires Go (brew install go). The rdpgw source ships no go.sum; the one in
# scripts/test-gateway/go.sum pins every module it needs, and Go checks each
# download against it.
#
# Usage: scripts/build-test-gateway.sh [--force] [--print-key]
# Output: build/test-gateway/bin/{rdpgw,rdpgw-auth}

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${VISTARA_ARCH:-arm64}"
WORK="$ROOT/build/test-gateway"
BIN="$WORK/bin"
STAMP="$BIN/.vistara-build-key"
GO_SUM="$ROOT/scripts/test-gateway/go.sum"

read -r RDPGW_VERSION RDPGW_SHA256 <"$ROOT/scripts/RDPGW_VERSION"
RDPGW_URL="https://codeload.github.com/bolkedebruin/rdpgw/tar.gz/refs/tags/v$RDPGW_VERSION"

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
die() { echo "error: $*" >&2; exit 1; }

BUILD_KEY="$(printf '%s\n' "$RDPGW_SHA256" "$ARCH" "$(sha256 "${BASH_SOURCE[0]}")" \
  "$(sha256 "$GO_SUM" 2>/dev/null || true)" | shasum -a 256 | cut -d' ' -f1)"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --print-key) echo "$BUILD_KEY"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ $FORCE -eq 0 && -f "$STAMP" && "$(cat "$STAMP")" == "$BUILD_KEY" ]]; then
  echo "Test gateway rdpgw $RDPGW_VERSION is up to date in $BIN"
  exit 0
fi
command -v go >/dev/null || die "Go not found. Install it with: brew install go"

rm -rf "$BIN" "$WORK/src" "$WORK/go"
mkdir -p "$BIN" "$WORK/src" "$WORK/downloads"

archive="$WORK/downloads/rdpgw-$RDPGW_VERSION.tar.gz"
if [[ ! -f "$archive" || "$(sha256 "$archive")" != "$RDPGW_SHA256" ]]; then
  curl --fail --location --silent --show-error --retry 3 --proto '=https' --output "$archive" "$RDPGW_URL"
fi
[[ "$(sha256 "$archive")" == "$RDPGW_SHA256" ]] || { rm -f "$archive"; die "checksum mismatch for $RDPGW_URL"; }
tar -xzf "$archive" -C "$WORK/src" --strip-components 1
[[ ! -e "$WORK/src/go.sum" ]] || die "rdpgw $RDPGW_VERSION ships a go.sum now; compare it with $GO_SUM"

# Modules go to a cache inside the build folder, removed afterwards.
export GOPATH="$WORK/go" GOMODCACHE="$WORK/go/mod" GOFLAGS="-mod=readonly -modcacherw"
export GOARCH="${ARCH/x86_64/amd64}" CGO_ENABLED=1
go version
if [[ ! -f "$GO_SUM" ]]; then
  # Bootstrap: resolve the modules once, checked against Go's checksum database,
  # and print the result to commit as scripts/test-gateway/go.sum.
  (cd "$WORK/src" && GOFLAGS=-modcacherw go mod tidy)
  echo "--- go.sum begin"; cat "$WORK/src/go.sum"; echo "--- go.sum end"
  die "no $GO_SUM yet; commit the go.sum printed above"
fi
cp "$GO_SUM" "$WORK/src/go.sum"
# The helper links PAM through cgo for its PAM mode; the tests use its NTLM mode.
(cd "$WORK/src" && go build -trimpath -o "$BIN/rdpgw" ./cmd/rdpgw && go build -trimpath -o "$BIN/rdpgw-auth" ./cmd/auth)
rm -rf "$WORK/go" "$WORK/src"

for tool in rdpgw rdpgw-auth; do
  [[ -x "$BIN/$tool" ]] || die "expected $tool in $BIN"
done
file "$BIN/rdpgw" "$BIN/rdpgw-auth"

echo "$BUILD_KEY" >"$STAMP"
echo "Done: test gateway in $BIN"
