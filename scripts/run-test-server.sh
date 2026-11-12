#!/bin/bash
#
# Starts the FreeRDP shadow test server on localhost with NLA and a freshly
# generated account, waits until it accepts connections, and prints the
# environment the integration tests read:
#
#   VISTARA_TEST_RDP_HOST, VISTARA_TEST_RDP_PORT,
#   VISTARA_TEST_RDP_USER, VISTARA_TEST_RDP_PASSWORD,
#   VISTARA_TEST_SERVER_LOG (the server reports received input there)
#
# The server keeps running after this script returns. Its PID is in
# build/test-server/run/server.pid and its log in build/test-server/run/server.log.
#
# Usage:  eval "$(scripts/run-test-server.sh)"   then   swift test ...

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="$ROOT/build/test-server/prefix"
RUN="$ROOT/build/test-server/run"
PORT="${VISTARA_TEST_RDP_PORT:-33890}"
USER_NAME="vistara-test"
# Throwaway credential for a server bound to localhost; it guards nothing.
PASSWORD="$(uuidgen)"

[[ -x "$PREFIX/bin/freerdp-shadow-cli" ]] || { echo "error: run scripts/build-test-server.sh first" >&2; exit 1; }

if [[ -f "$RUN/server.pid" ]]; then kill "$(cat "$RUN/server.pid")" 2>/dev/null || true; fi
rm -rf "$RUN"
mkdir -p "$RUN/config"

"$PREFIX/bin/winpr-hash" -u "$USER_NAME" -p "$PASSWORD" -f sam >"$RUN/SAM"

# The server writes its self-signed certificate under XDG_CONFIG_HOME.
XDG_CONFIG_HOME="$RUN/config" HOME="$RUN" nohup "$PREFIX/bin/freerdp-shadow-cli" \
  "/port:$PORT" /bind-address:127.0.0.1 /sec:nla "/sam-file:$RUN/SAM" \
  >"$RUN/server.log" 2>&1 &
echo $! >"$RUN/server.pid"

for _ in $(seq 1 50); do
  if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
    echo "VISTARA_TEST_RDP_HOST=127.0.0.1"
    echo "VISTARA_TEST_RDP_PORT=$PORT"
    echo "VISTARA_TEST_RDP_USER=$USER_NAME"
    echo "VISTARA_TEST_RDP_PASSWORD=$PASSWORD"
    echo "VISTARA_TEST_SERVER_LOG=$RUN/server.log"
    exit 0
  fi
  if ! kill -0 "$(cat "$RUN/server.pid")" 2>/dev/null; then break; fi
  sleep 0.2
done

echo "error: test server did not start. Log:" >&2
cat "$RUN/server.log" >&2
exit 1
