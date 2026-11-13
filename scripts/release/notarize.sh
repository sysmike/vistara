#!/bin/bash
#
# Notarizes a file with Apple and staples the ticket to it. An app is
# submitted as a zip; a DMG as it is.
#
# Usage: scripts/release/notarize.sh <Vistara.app | Vistara.dmg>
#
# Environment (an App Store Connect API key with the Developer role):
#   VISTARA_NOTARY_KEY_PATH   path to the key's .p8 file
#   VISTARA_NOTARY_KEY_ID     the key's ID
#   VISTARA_NOTARY_ISSUER     the issuer ID

set -euo pipefail

target="${1:?usage: notarize.sh <app or dmg>}"
: "${VISTARA_NOTARY_KEY_PATH:?}" "${VISTARA_NOTARY_KEY_ID:?}" "${VISTARA_NOTARY_ISSUER:?}"

submission="$target"
if [[ -d "$target" ]]; then
  submission="$(mktemp -d)/$(basename "$target").zip"
  ditto -c -k --keepParent "$target" "$submission"
fi

result="$(xcrun notarytool submit "$submission" --wait --output-format json \
  --key "$VISTARA_NOTARY_KEY_PATH" --key-id "$VISTARA_NOTARY_KEY_ID" --issuer "$VISTARA_NOTARY_ISSUER")"
echo "$result"
id="$(plutil -extract id raw - <<<"$result")"
status="$(plutil -extract status raw - <<<"$result")"
if [[ "$status" != "Accepted" ]]; then
  xcrun notarytool log "$id" \
    --key "$VISTARA_NOTARY_KEY_PATH" --key-id "$VISTARA_NOTARY_KEY_ID" --issuer "$VISTARA_NOTARY_ISSUER" || true
  echo "error: notarization of $(basename "$target") ended as $status" >&2
  exit 1
fi

xcrun stapler staple "$target"
xcrun stapler validate "$target"
