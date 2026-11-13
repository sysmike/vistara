#!/bin/bash
#
# Checks the test gateway with FreeRDP's minimal client, sfreerdp, so a fault
# in the gateway setup shows up apart from Vistara's own gateway support:
#
#   1. The gateway user reaches the test server through the gateway.
#   2. A wrong gateway password is refused.
#   3. An address outside the gateway's policy is refused.
#
# Each case is told apart by the lines it adds to the gateway and server logs.
#
# Usage: after scripts/run-test-server.sh and scripts/run-test-gateway.sh have
# put their environment in this shell, run scripts/check-test-gateway.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT="$ROOT/build/test-server/prefix/bin/sfreerdp"
RUN="$ROOT/build/test-gateway/run"

[[ -x "$CLIENT" ]] || { echo "error: run scripts/build-test-server.sh first" >&2; exit 1; }
for name in VISTARA_TEST_RDP_HOST VISTARA_TEST_RDP_PORT VISTARA_TEST_RDP_USER VISTARA_TEST_RDP_PASSWORD \
  VISTARA_TEST_SERVER_LOG VISTARA_TEST_GATEWAY_HOST VISTARA_TEST_GATEWAY_PORT VISTARA_TEST_GATEWAY_USER \
  VISTARA_TEST_GATEWAY_PASSWORD VISTARA_TEST_GATEWAY_LOG VISTARA_TEST_GATEWAY_REFUSED_HOST; do
  [[ -n "${!name:-}" ]] || { echo "error: $name is not set; start the test server and gateway first" >&2; exit 1; }
done

GATEWAY_LOG="$VISTARA_TEST_GATEWAY_LOG"
SERVER_LOG="$VISTARA_TEST_SERVER_LOG"
failures=0

count() { grep -c -F -- "$1" "$2" || true; }

# Runs the client in the background with its output in $RUN/client-<name>.log.
# The credentials are throwaway ones for local test servers.
start_client() {
  local name="$1" target="$2" gateway_password="$3"
  "$CLIENT" "/v:$target" "/u:$VISTARA_TEST_RDP_USER" "/p:$VISTARA_TEST_RDP_PASSWORD" /cert:ignore \
    "/gateway:g:$VISTARA_TEST_GATEWAY_HOST:$VISTARA_TEST_GATEWAY_PORT,u:$VISTARA_TEST_GATEWAY_USER,p:$gateway_password,type:http" \
    </dev/null >"$RUN/client-$name.log" 2>&1 &
  client_pid=$!
}

stop_client() {
  kill "$client_pid" 2>/dev/null || true
  sleep 0.5
  kill -9 "$client_pid" 2>/dev/null || true
  wait "$client_pid" 2>/dev/null || true
}

# Waits up to $3 seconds for the line $1 to appear in log $2 more often than $4 times.
wait_for_line() {
  local line="$1" log="$2" seconds="$3" before="$4"
  for _ in $(seq 1 $((seconds * 5))); do
    [[ "$(count "$line" "$log")" -gt "$before" ]] && return 0
    sleep 0.2
  done
  return 1
}

report() {
  local name="$1" passed="$2"
  if [[ "$passed" == 1 ]]; then
    echo "ok: $name"
  else
    echo "FAILED: $name. Client output:"
    sed 's/^/  /' "$RUN/client-$3.log"
    failures=$((failures + 1))
  fi
}

allowed="$VISTARA_TEST_RDP_HOST:$VISTARA_TEST_RDP_PORT"
refused="$VISTARA_TEST_GATEWAY_REFUSED_HOST:3389"

# 1. Through the gateway to the test server.
connected_before="$(count "Establishing connection to RDP server: $allowed" "$GATEWAY_LOG")"
activated_before="$(count "is activated" "$SERVER_LOG")"
start_client allowed "$allowed" "$VISTARA_TEST_GATEWAY_PASSWORD"
passed=0
if wait_for_line "Establishing connection to RDP server: $allowed" "$GATEWAY_LOG" 30 "$connected_before" &&
  wait_for_line "is activated" "$SERVER_LOG" 30 "$activated_before"; then
  passed=1
fi
stop_client
report "the gateway user reaches the test server through the gateway" "$passed" allowed

# 2. A wrong gateway password.
connected_before="$(count "Establishing connection to RDP server" "$GATEWAY_LOG")"
rejected_before="$(count "Failed to process NTLM authenticate message" "$GATEWAY_LOG")"
start_client wrong-password "$allowed" "not-the-password"
passed=0
if wait_for_line "Failed to process NTLM authenticate message" "$GATEWAY_LOG" 30 "$rejected_before"; then
  # The client gives up; the gateway never reaches the server for it.
  for _ in $(seq 1 50); do kill -0 "$client_pid" 2>/dev/null || break; sleep 0.2; done
  if ! kill -0 "$client_pid" 2>/dev/null &&
    [[ "$(count "Establishing connection to RDP server" "$GATEWAY_LOG")" -eq "$connected_before" ]]; then
    passed=1
  fi
fi
stop_client
report "a wrong gateway password is refused" "$passed" wrong-password

# 3. An address outside the gateway's policy.
refused_before="$(count "Not allowed to connect to $refused by policy handler" "$GATEWAY_LOG")"
start_client refused-host "$refused" "$VISTARA_TEST_GATEWAY_PASSWORD"
passed=0
if wait_for_line "Not allowed to connect to $refused by policy handler" "$GATEWAY_LOG" 30 "$refused_before"; then
  for _ in $(seq 1 50); do kill -0 "$client_pid" 2>/dev/null || break; sleep 0.2; done
  kill -0 "$client_pid" 2>/dev/null || passed=1
fi
stop_client
report "an address outside the gateway's policy is refused" "$passed" refused-host

if [[ $failures -gt 0 ]]; then
  echo "Gateway log:"
  sed 's/^/  /' "$GATEWAY_LOG"
  exit 1
fi
