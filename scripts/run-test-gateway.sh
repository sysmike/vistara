#!/bin/bash
#
# Starts the rdpgw test gateway on localhost in front of the test server, waits
# until it answers, and prints the environment the gateway tests read:
#
#   VISTARA_TEST_GATEWAY_HOST, VISTARA_TEST_GATEWAY_PORT,
#   VISTARA_TEST_GATEWAY_USER, VISTARA_TEST_GATEWAY_PASSWORD,
#   VISTARA_TEST_GATEWAY_CA (the certificate authority that signed the
#     gateway's certificate; trust it to verify the gateway),
#   VISTARA_TEST_GATEWAY_LOG (the gateway and its authentication helper log
#     there),
#   VISTARA_TEST_GATEWAY_REFUSED_HOST (an address the gateway refuses to reach)
#
# The gateway authenticates with NTLM. It knows one user with a freshly
# generated password; any other name or password fails. It lets that user reach
# the test server, 127.0.0.1 on VISTARA_TEST_RDP_PORT, and nothing else.
#
# Both programs keep running after this script returns. Their PIDs are in
# build/test-gateway/run/{gateway,auth}.pid.
#
# Usage:  eval "$(scripts/run-test-gateway.sh)"   after   scripts/run-test-server.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/build/test-gateway/bin"
RUN="$ROOT/build/test-gateway/run"
PORT="${VISTARA_TEST_GATEWAY_PORT:-34443}"
RDP_PORT="${VISTARA_TEST_RDP_PORT:-33890}"
USER_NAME="vistara-gateway"
# Throwaway credential for a gateway bound to localhost; it guards nothing.
PASSWORD="$(uuidgen)"
# TEST-NET-1 (RFC 5737): never a real host. The gateway refuses it by policy
# before trying to reach it.
REFUSED_HOST="192.0.2.10"

[[ -x "$BIN/rdpgw" && -x "$BIN/rdpgw-auth" ]] || { echo "error: run scripts/build-test-gateway.sh first" >&2; exit 1; }

for name in gateway auth; do
  if [[ -f "$RUN/$name.pid" ]]; then kill "$(cat "$RUN/$name.pid")" 2>/dev/null || true; fi
done
rm -rf "$RUN"
mkdir -p "$RUN"

# A certificate authority and a certificate it signs for localhost.
cat >"$RUN/ca.cnf" <<'EOF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = ca_ext
[dn]
CN = Vistara Test Gateway CA
[ca_ext]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
EOF
cat >"$RUN/gateway.cnf" <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = localhost
[gateway_ext]
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost,IP:127.0.0.1
authorityKeyIdentifier = keyid
EOF
{
  openssl req -x509 -new -newkey rsa:2048 -nodes -sha256 -days 7 -config "$RUN/ca.cnf" \
    -keyout "$RUN/ca.key" -out "$RUN/ca.pem"
  openssl req -new -newkey rsa:2048 -nodes -sha256 -config "$RUN/gateway.cnf" \
    -keyout "$RUN/gateway.key" -out "$RUN/gateway.csr"
  openssl x509 -req -sha256 -days 7 -in "$RUN/gateway.csr" -CA "$RUN/ca.pem" -CAkey "$RUN/ca.key" \
    -CAcreateserial -extfile "$RUN/gateway.cnf" -extensions gateway_ext -out "$RUN/gateway.pem"
} >"$RUN/openssl.log" 2>&1 || { cat "$RUN/openssl.log" >&2; exit 1; }

umask 077
cat >"$RUN/rdpgw-auth.yaml" <<EOF
Users:
  - Username: "$USER_NAME"
    Password: "$PASSWORD"
EOF
cat >"$RUN/rdpgw.yaml" <<EOF
Server:
  Authentication:
    - ntlm
  Tls: enable
  CertFile: "$RUN/gateway.pem"
  KeyFile: "$RUN/gateway.key"
  Port: $PORT
  GatewayAddress: "localhost:$PORT"
  AuthSocket: "$RUN/auth.sock"
  HostSelection: roundrobin
  Hosts:
    - "127.0.0.1:$RDP_PORT"
Caps:
  TokenAuth: false
EOF
umask 022

stop() { kill "$(cat "$RUN/auth.pid")" "$(cat "$RUN/gateway.pid" 2>/dev/null)" 2>/dev/null || true; }
fail() {
  echo "error: $1. Log:" >&2
  cat "$RUN/gateway.log" >&2
  stop
  exit 1
}

nohup "$BIN/rdpgw-auth" -c "$RUN/rdpgw-auth.yaml" -s "$RUN/auth.sock" >>"$RUN/gateway.log" 2>&1 &
echo $! >"$RUN/auth.pid"
for _ in $(seq 1 50); do
  [[ -S "$RUN/auth.sock" ]] && break
  kill -0 "$(cat "$RUN/auth.pid")" 2>/dev/null || break
  sleep 0.2
done
[[ -S "$RUN/auth.sock" ]] || fail "the authentication helper did not start"

nohup "$BIN/rdpgw" -c "$RUN/rdpgw.yaml" >>"$RUN/gateway.log" 2>&1 &
echo $! >"$RUN/gateway.pid"
# Ready when it answers HTTPS with a certificate the test authority signed,
# asking for authentication.
status=""
for _ in $(seq 1 50); do
  status="$(curl --silent --output /dev/null --write-out '%{http_code}' --cacert "$RUN/ca.pem" \
    "https://localhost:$PORT/remoteDesktopGateway/" || true)"
  [[ "$status" == "401" ]] && break
  kill -0 "$(cat "$RUN/gateway.pid")" 2>/dev/null || break
  sleep 0.2
done
[[ "$status" == "401" ]] || fail "the gateway did not start (last HTTP status: ${status:-none})"

echo "VISTARA_TEST_GATEWAY_HOST=localhost"
echo "VISTARA_TEST_GATEWAY_PORT=$PORT"
echo "VISTARA_TEST_GATEWAY_USER=$USER_NAME"
echo "VISTARA_TEST_GATEWAY_PASSWORD=$PASSWORD"
echo "VISTARA_TEST_GATEWAY_CA=$RUN/ca.pem"
echo "VISTARA_TEST_GATEWAY_LOG=$RUN/gateway.log"
echo "VISTARA_TEST_GATEWAY_REFUSED_HOST=$REFUSED_HOST"
