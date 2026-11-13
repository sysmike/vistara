#!/bin/bash
#
# Compares the pinned FreeRDP and OpenSSL releases with the newest upstream
# ones (FreeRDP 3.x; OpenSSL on the pinned release line, such as 3.5) and
# opens an issue for each newer release, once. Used by the scheduled
# upstream-watch workflow; needs gh with access to the repository.
#
# Environment:
#   VISTARA_WATCH_DRY_RUN=1   say what would be opened, open nothing
#   GH_REPO                   the repository to open issues in

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Prints the newest release among tags matching the pattern, with the part
# the pattern captures as the version.
newest() {
  local repository="$1" pattern="$2"
  gh api "repos/$repository/releases?per_page=100" --jq '.[] | select(.prerelease | not) | .tag_name' |
    sed -nE "s/$pattern/\\1/p" | sort -V | tail -1
}

# Whether $2 is a later version than $1.
is_newer() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$2" ]]
}

report() {
  local name="$1" pinned="$2" latest="$3" notes="$4"
  if [[ -z "$latest" ]]; then
    echo "error: found no $name release upstream" >&2
    return 1
  fi
  if ! is_newer "$pinned" "$latest"; then
    echo "$name: pinned $pinned is current (newest $latest)"
    return 0
  fi
  local title="build: $name $latest is available"
  # Once per release: an issue that was closed, for example because the bump
  # was declined, is not opened again.
  local existing
  existing="$(gh issue list --state all --search "\"$title\" in:title" --json number --jq 'length')"
  if [[ "$existing" != "0" ]]; then
    echo "$name: $latest is newer than $pinned; an issue already exists"
    return 0
  fi
  local body
  body="$(cat <<BODY
$name $latest is out; Vistara pins $pinned.

Release notes: $notes

Follow docs/UPDATING-FREERDP.md: read the notes for security fixes and API changes first, then pin the release with \`scripts/update-pin.sh\`, rebuild, and run the tests. Security fixes go first.

Opened by the upstream-watch workflow.
BODY
)"
  if [[ "${VISTARA_WATCH_DRY_RUN:-0}" == "1" ]]; then
    echo "$name: $latest is newer than $pinned; would open \"$title\""
  else
    gh issue create --title "$title" --body "$body"
  fi
}

read -r freerdp_pinned _ <"$ROOT/FREERDP_VERSION"
read -r openssl_pinned _ <"$ROOT/scripts/OPENSSL_VERSION"
openssl_line="${openssl_pinned%.*}"

freerdp_latest="$(newest FreeRDP/FreeRDP '^(3\.[0-9]+\.[0-9]+)$')"
openssl_latest="$(newest openssl/openssl "^openssl-(${openssl_line//./\\.}\\.[0-9]+)\$")"

status=0
report FreeRDP "$freerdp_pinned" "$freerdp_latest" \
  "https://github.com/FreeRDP/FreeRDP/releases/tag/$freerdp_latest" || status=1
report OpenSSL "$openssl_pinned" "$openssl_latest" \
  "https://github.com/openssl/openssl/releases/tag/openssl-$openssl_latest" || status=1
exit $status
