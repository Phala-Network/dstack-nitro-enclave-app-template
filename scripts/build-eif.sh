#!/usr/bin/env bash
# Build the Nitro Enclave EIF image from the app/ directory.
#
# Inputs (env):
#   DSTACK_UTIL  – path to a pre-built dstack-util musl binary
#                  (default: downloaded from DSTACK_VERSION release)
#   DSTACK_VERSION – dstack release tag to fetch dstack-util from
#                    (default: v0.5.8)
#   KMS_URL      – baked into the entrypoint; affects measurements
#                  (default: https://kms.example.com:12001)
#   APP_ID       – baked into the entrypoint; affects measurements
#                  (default: empty / placeholder)
#   OUTPUT_DIR   – where to write the .eif and measurements.json
#                  (default: ./output)
#
# Outputs:
#   $OUTPUT_DIR/enclave.eif          – the EIF image
#   $OUTPUT_DIR/measurements.json    – PCR values + OS_IMAGE_HASH
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DSTACK_VERSION="${DSTACK_VERSION:-v0.5.8}"
KMS_URL="${KMS_URL:-https://kms.example.com:12001}"
APP_ID="${APP_ID:-}"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT_DIR}/output}"

mkdir -p "${OUTPUT_DIR}"

# ── 1. Obtain dstack-util ────────────────────────────────────────────
if [[ -n "${DSTACK_UTIL:-}" && -f "${DSTACK_UTIL}" ]]; then
  echo "[build] Using provided dstack-util: ${DSTACK_UTIL}"
  cp "${DSTACK_UTIL}" "${ROOT_DIR}/app/dstack-util"
else
  echo "[build] Building dstack-util from dstack ${DSTACK_VERSION} ..."
  DSTACK_SRC="$(mktemp -d)"
  git clone --depth 1 --branch "${DSTACK_VERSION}" \
    https://github.com/Dstack-TEE/dstack.git "${DSTACK_SRC}" 2>&1 | tail -1
  (
    cd "${DSTACK_SRC}"
    cargo build --release -p dstack-util --target x86_64-unknown-linux-musl 2>&1 | tail -5
  )
  cp "${DSTACK_SRC}/target/x86_64-unknown-linux-musl/release/dstack-util" \
     "${ROOT_DIR}/app/dstack-util"
  rm -rf "${DSTACK_SRC}"
fi
chmod +x "${ROOT_DIR}/app/dstack-util"

# ── 2. Template substitution ─────────────────────────────────────────
# KMS_URL and APP_ID are baked into the entrypoint script.  Changing
# them changes the Docker image content → changes PCR measurements.
WORK_DIR="$(mktemp -d)"
cp -a "${ROOT_DIR}/app/." "${WORK_DIR}/"

KMS_URL_ESC=$(printf '%s' "${KMS_URL}" | sed -e 's/[\\/&]/\\&/g')
APP_ID_ESC=$(printf '%s' "${APP_ID}" | sed -e 's/[\\/&]/\\&/g')
sed -i \
  -e "s/__KMS_URL__/${KMS_URL_ESC}/g" \
  -e "s/__APP_ID__/${APP_ID_ESC}/g" \
  "${WORK_DIR}/entrypoint.sh"

# ── 3. Build Docker image ────────────────────────────────────────────
IMAGE_TAG="nitro-enclave-app"
echo "[build] Building Docker image ${IMAGE_TAG} ..."
docker build -t "${IMAGE_TAG}" -f "${WORK_DIR}/Dockerfile" "${WORK_DIR}" >/dev/null

# ── 4. Build EIF and capture measurements ─────────────────────────────
echo "[build] Building EIF ..."
nitro-cli build-enclave \
  --docker-uri "${IMAGE_TAG}" \
  --output-file "${OUTPUT_DIR}/enclave.eif" \
  > "${OUTPUT_DIR}/nitro-build.json"

PCR0=$(jq -r '.Measurements.PCR0' "${OUTPUT_DIR}/nitro-build.json")
PCR1=$(jq -r '.Measurements.PCR1' "${OUTPUT_DIR}/nitro-build.json")
PCR2=$(jq -r '.Measurements.PCR2' "${OUTPUT_DIR}/nitro-build.json")

# OS_IMAGE_HASH = sha256(PCR0 || PCR1 || PCR2)  — the value registered
# on-chain in the DstackKms contract's image whitelist.
CODE_HASH=$(python3 -c "
import hashlib, sys
pcrs = bytes.fromhex('${PCR0}') + bytes.fromhex('${PCR1}') + bytes.fromhex('${PCR2}')
print('0x' + hashlib.sha256(pcrs).hexdigest())
")

# ── 5. Write measurements.json ───────────────────────────────────────
jq -n \
  --arg pcr0 "${PCR0}" \
  --arg pcr1 "${PCR1}" \
  --arg pcr2 "${PCR2}" \
  --arg code_hash "${CODE_HASH}" \
  --arg kms_url "${KMS_URL}" \
  --arg app_id "${APP_ID}" \
  --arg dstack_version "${DSTACK_VERSION}" \
  --arg built_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    PCR0: $pcr0,
    PCR1: $pcr1,
    PCR2: $pcr2,
    code_hash: $code_hash,
    kms_url: $kms_url,
    app_id: $app_id,
    dstack_version: $dstack_version,
    built_at: $built_at
  }' > "${OUTPUT_DIR}/measurements.json"

echo "[build] Done."
echo "  EIF:          ${OUTPUT_DIR}/enclave.eif"
echo "  Measurements: ${OUTPUT_DIR}/measurements.json"
echo ""
echo "  PCR0: ${PCR0}"
echo "  PCR1: ${PCR1}"
echo "  PCR2: ${PCR2}"
echo "  CODE_HASH (OS_IMAGE_HASH): ${CODE_HASH}"

# Clean up
rm -rf "${WORK_DIR}"
