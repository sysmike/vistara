#!/bin/bash
#
# Pins a new FreeRDP or OpenSSL release: downloads the tarball, checks it
# against the checksum the project publishes next to it, and writes the
# version and SHA-256 into the pin file. See docs/UPDATING-FREERDP.md.
#
# Usage: scripts/update-pin.sh freerdp 3.33.2
#        scripts/update-pin.sh openssl 3.5.10

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "error: $*" >&2; exit 1; }

project="${1:-}"
version="${2:-}"
[[ -n "$project" && -n "$version" ]] || die "usage: update-pin.sh <freerdp|openssl> <version>"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "not a release version: $version"

case "$project" in
  freerdp)
    pin="$ROOT/FREERDP_VERSION"
    url="https://github.com/FreeRDP/FreeRDP/releases/download/$version/freerdp-$version.tar.gz"
    notes="https://github.com/FreeRDP/FreeRDP/releases/tag/$version"
    ;;
  openssl)
    pin="$ROOT/scripts/OPENSSL_VERSION"
    url="https://github.com/openssl/openssl/releases/download/openssl-$version/openssl-$version.tar.gz"
    notes="https://github.com/openssl/openssl/releases/tag/openssl-$version"
    ;;
  *) die "unknown project: $project (freerdp or openssl)" ;;
esac

if command -v shasum >/dev/null; then sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else sha256() { sha256sum "$1" | cut -d' ' -f1; }; fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl --fail --location --silent --show-error --retry 3 --proto '=https' --output "$work/release.tar.gz" "$url" ||
  die "cannot download $url"
curl --fail --location --silent --show-error --retry 3 --proto '=https' --output "$work/release.sha256" "$url.sha256" ||
  die "cannot download $url.sha256"

actual="$(sha256 "$work/release.tar.gz")"
published="$(grep -Eo '[0-9a-f]{64}' "$work/release.sha256" | head -1)"
[[ "$actual" == "$published" ]] || die "checksum mismatch: computed $actual, published $published"

previous="$(cat "$pin")"
echo "$version $actual" >"$pin"
echo "Pinned $project $version"
echo "  was: $previous"
echo "  now: $(cat "$pin")"
echo "Release notes: $notes"
echo "Next: docs/UPDATING-FREERDP.md, from 'Rebuild'."
