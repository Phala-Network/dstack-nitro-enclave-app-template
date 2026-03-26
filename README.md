# Nitro Enclave Template

Template repository for building [dstack](https://github.com/Dstack-TEE/dstack) Nitro Enclave applications with reproducible measurements and Sigstore attestation.

## What this does

1. Builds a minimal Alpine-based Docker image containing **dstack-util** and your enclave entrypoint
2. Converts the Docker image to an AWS Nitro **EIF** (Enclave Image File) using `nitro-cli build-enclave`
3. Extracts **PCR measurements** (PCR0, PCR1, PCR2) and computes **OS_IMAGE_HASH** (`sha256(PCR0 || PCR1 || PCR2)`) — this is the value you register on-chain in the DstackKms contract
4. Attests the measurements via **Sigstore** (Rekor transparency log) so anyone can verify the build provenance
5. Publishes the EIF, measurements, and Sigstore bundle as a **GitHub Release**

## Repository structure

```
app/
  Dockerfile          # Enclave image definition (Alpine + dstack-util)
  entrypoint.sh       # Enclave startup script (template with __KMS_URL__ / __APP_ID__)
  root_ca.pem         # ⚠️ KMS root CA certificate — MUST replace before building
scripts/
  build-eif.sh        # Local build script (for development / manual builds)
.github/workflows/
  build-and-release.yml   # CI pipeline: build → measure → attest → release
```

## Quick start

### 1. Use this template

Click **"Use this template"** on GitHub, or:

```bash
gh repo create my-enclave-app --template <this-repo> --private
```

### 2. Replace the KMS root CA certificate

> **⚠️ This step is required.** The enclave pins the KMS TLS connection using `app/root_ca.pem`. The placeholder file shipped with this template is **not a valid certificate** — you must replace it with your KMS instance's root CA before building.

Obtain the root CA from your running KMS:

```bash
curl -sk https://<kms-host>:12001/prpc/KmsService.GetTempCaCert | jq -r .caCert > app/root_ca.pem
```

The root CA is baked into the enclave image and **affects the OS_IMAGE_HASH**. If the KMS root CA changes (e.g. KMS is re-bootstrapped), you must update this file and rebuild.

### 3. Customize your enclave app

Edit `app/entrypoint.sh` to implement your enclave logic. The template ships with a `dstack-util get-keys` example that fetches application keys from a dstack KMS.

The `__KMS_URL__`, `__APP_ID__`, and `app/root_ca.pem` are all baked into the Docker image. **Changing any of them changes the PCR measurements**, so the same values must be used for both measurement preview and production builds.

### 3. Create a release

The CI runs on GitHub's standard `ubuntu-latest` runners — no special hardware needed. `nitro-cli build-enclave` only converts a Docker image to EIF format and computes measurements; Nitro hardware is only required to *run* the enclave.

Push a version tag to trigger the build:

```bash
git tag v0.1.0
git push origin v0.1.0
```

Or use **Actions → Run workflow** for a manual build with custom KMS_URL / APP_ID.

### 4. Register the OS_IMAGE_HASH on-chain

After the release is created, copy the `OS_IMAGE_HASH` from the release page and register it:

```bash
cd dstack/kms/auth-eth
npx hardhat kms:add-image <OS_IMAGE_HASH> --network <your-network>
```

## Local build

You can build locally (needs Docker and `nitro-cli` installed):

```bash
# Option A: with a pre-built dstack-util binary
DSTACK_UTIL=/path/to/dstack-util \
KMS_URL=https://your-kms:12001 \
APP_ID=0x... \
  ./scripts/build-eif.sh

# Option B: build dstack-util from source (needs Rust + musl target)
KMS_URL=https://your-kms:12001 \
APP_ID=0x... \
DSTACK_COMMIT=14963a2ccb0ec7bef8a496c1ac5ac40f5593145d \
  ./scripts/build-eif.sh
```

Outputs land in `./output/`:
- `enclave.eif` — the EIF image, ready to run with `nitro-cli run-enclave`
- `measurements.json` — PCR values and CODE_HASH

## Verifying Sigstore attestation

Release builds are attested via Sigstore. The OS_IMAGE_HASH is directly searchable on Rekor:

```
https://search.sigstore.dev/?hash=<os_image_hash without 0x prefix>
```

To verify locally:

```bash
# Download release assets
gh release download v0.1.0 -p 'measurements.json' -p 'measurements.sigstore.json'

# Reconstruct the PCR payload (the blob whose sha256 = OS_IMAGE_HASH)
python3 -c "
import sys, json
m = json.load(open('measurements.json'))
sys.stdout.buffer.write(
    bytes.fromhex(m['PCR0']) + bytes.fromhex(m['PCR1']) + bytes.fromhex(m['PCR2'])
)
" > pcr_payload.bin

# Verify
cosign verify-blob-attestation \
  --bundle measurements.sigstore.json \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp "github.com/<owner>/<repo>" \
  --type https://dstack.dev/nitro-enclave/measurements/v1 \
  pcr_payload.bin
```

## How measurements work

AWS Nitro Enclaves produce three **Platform Configuration Registers** (PCRs) when building an EIF:

| PCR | What it measures |
|-----|-----------------|
| PCR0 | Enclave image (hash of the full EIF content) |
| PCR1 | Linux kernel and boot ramdisk |
| PCR2 | Application layer (your Docker image filesystem) |

The **OS_IMAGE_HASH** is computed as:

```
OS_IMAGE_HASH = sha256(PCR0 || PCR1 || PCR2)
```

This is the value registered in the DstackKms smart contract's image whitelist. When the enclave requests keys from KMS, the KMS verifies that the enclave's attestation quote contains PCR values that hash to a whitelisted OS_IMAGE_HASH.

**Important:** The following are all baked into the Docker image and affect the OS_IMAGE_HASH:
- `KMS_URL` and `APP_ID` (substituted into `entrypoint.sh`)
- `app/root_ca.pem` (KMS root CA certificate)

Changing any of them changes PCR2, which changes OS_IMAGE_HASH. Always use identical values for preview (`--show-mrs`) and production builds.

## License

MIT
