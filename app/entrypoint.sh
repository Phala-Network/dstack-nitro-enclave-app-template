#!/bin/sh
set -e

# ── Enclave bootstrap ────────────────────────────────────────────────
# Loopback is required for local sockets; enclave starts with no interfaces.
ip link set lo up 2>/dev/null || ifconfig lo up 2>/dev/null || true

# Enclave has no /etc/resolv.conf by default.
mkdir -p /etc 2>/dev/null || true
printf "nameserver 8.8.8.8\nnameserver 8.8.4.4\n" > /etc/resolv.conf 2>/dev/null || true

# ── Vsock proxy bridge ───────────────────────────────────────────────
# The host runs a forward HTTP proxy (tinyproxy / squid) on port 3128
# and bridges it over vsock CID 3 (host). We expose it locally so
# dstack-util can reach the KMS over HTTPS through the proxy.
socat TCP-LISTEN:3128,fork,reuseaddr VSOCK-CONNECT:3:3128 &
sleep 1

# ── Environment ──────────────────────────────────────────────────────
# These placeholders are replaced at Docker-build time by the CI
# pipeline (see scripts/build-eif.sh).  Changing them changes the EIF
# measurements, so the values used for --show-mrs MUST match the ones
# baked into the production image.
KMS_URL="__KMS_URL__"
APP_ID="__APP_ID__"

ARGS="--kms-url ${KMS_URL}"
if [ -n "${APP_ID}" ] && [ "${APP_ID}" != "__APP_ID__" ]; then
  ARGS="${ARGS} --app-id ${APP_ID}"
fi

# ── Run dstack-util ──────────────────────────────────────────────────
HTTPS_PROXY="http://127.0.0.1:3128"
HTTP_PROXY="${HTTPS_PROXY}"
ALL_PROXY="${HTTPS_PROXY}"
NO_PROXY="127.0.0.1,localhost"

echo "[enclave] running dstack-util get-keys" >&2
set +e
KEYS=$(HTTPS_PROXY="${HTTPS_PROXY}" HTTP_PROXY="${HTTP_PROXY}" \
       ALL_PROXY="${ALL_PROXY}" NO_PROXY="${NO_PROXY}" \
       /app/dstack-util get-keys ${ARGS} 2>/tmp/get_keys.stderr)
RET=$?
set -e

echo "[enclave] dstack-util exit=${RET}" >&2
if [ -s /tmp/get_keys.stderr ]; then
  echo "[enclave] stderr:" >&2
  cat /tmp/get_keys.stderr >&2
fi
if [ "${RET}" -ne 0 ]; then
  sleep 5
  exit "${RET}"
fi

# ── Return keys to host via vsock ────────────────────────────────────
echo "[enclave] keys-bytes=$(printf '%s' "${KEYS}" | wc -c)" >&2
printf '%s' "${KEYS}" | socat -u - VSOCK-CONNECT:3:9999
sleep 2
