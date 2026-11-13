#!/bin/bash
#
# Writes SHA256SUMS for the release files, after any stapling has changed them.
#
# Usage: scripts/release/checksums.sh <file>...

set -euo pipefail
cd "$(dirname "$1")"
names=()
for file in "$@"; do names+=("$(basename "$file")"); done
shasum -a 256 "${names[@]}" | tee SHA256SUMS
