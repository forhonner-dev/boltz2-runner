#!/bin/bash
set -euo pipefail

source /opt/miniforge/bin/activate boltz2

# --- Configuration from environment variables ---
# Required:
#   GCS_BUCKET       - GCS bucket name
#   GCS_INPUT_PREFIX - GCS prefix for inputs (e.g. "cofold-input/<workflow_id>")
#   JOB_NAME         - name for this job; also the GCS output prefix
#                      (e.g. "cofold-output/<workflow_id>")
# Optional:
#   GCS_SA_KEY_B64    - base64-encoded SA JSON. ONLY needed when running
#                       outside of a workload-identity-enabled environment
#                       (e.g., local docker, Vast.AI). On GKE Workload
#                       Identity, leave it unset and Application Default
#                       Credentials are picked up automatically.
#   RECYCLING_STEPS   - recycling iterations (default: 3)
#   DIFFUSION_SAMPLES - number of structure samples (default: 1)
#   USE_MSA_SERVER    - set to "true" to use mmseqs2 MSA server

WORKDIR="/workspace/boltz2_run"
mkdir -p "$WORKDIR/inputs" "$WORKDIR/results" "$BOLTZ_CACHE"

# Optional explicit SA key path — only set GOOGLE_APPLICATION_CREDENTIALS when
# a base64 key is actually provided. Otherwise google-cloud-storage picks up
# Workload Identity / metadata-server credentials transparently.
GCS_SA_KEY_PATH=""
if [ -n "${GCS_SA_KEY_B64:-}" ]; then
    echo "GCS_SA_KEY_B64 is set — writing key to /tmp/gcs_key.json (legacy path)."
    echo "$GCS_SA_KEY_B64" | base64 -d > /tmp/gcs_key.json
    export GOOGLE_APPLICATION_CREDENTIALS=/tmp/gcs_key.json
    GCS_SA_KEY_PATH=/tmp/gcs_key.json
else
    echo "GCS_SA_KEY_B64 not set — using Application Default Credentials (Workload Identity)."
fi

# Download model weights on first run
echo "Ensuring model weights are cached..."
boltz predict --help > /dev/null 2>&1 || true

# Download inputs from GCS using ADC (or the SA key if one was provided).
echo "Downloading inputs from gs://$GCS_BUCKET/$GCS_INPUT_PREFIX/..."
python -c "
from google.cloud import storage
client = storage.Client()
bucket = client.bucket('$GCS_BUCKET')
blobs = list(bucket.list_blobs(prefix='$GCS_INPUT_PREFIX/'))
for blob in blobs:
    fname = blob.name.split('/')[-1]
    if fname:
        blob.download_to_filename('$WORKDIR/inputs/' + fname)
        print(f'  Downloaded {fname}')
print('Inputs downloaded.')
"

JOB_NAME="${JOB_NAME:-boltz2_$(date +%Y%m%d_%H%M%S)}"
RECYCLING_STEPS="${RECYCLING_STEPS:-3}"
DIFFUSION_SAMPLES="${DIFFUSION_SAMPLES:-1}"
USE_MSA_SERVER="${USE_MSA_SERVER:-false}"

echo "=========================================="
echo "Boltz2 Job: $JOB_NAME"
echo "Recycling steps: $RECYCLING_STEPS"
echo "Diffusion samples: $DIFFUSION_SAMPLES"
echo "MSA server: $USE_MSA_SERVER"
echo "=========================================="

MSA_FLAG=""
if [ "$USE_MSA_SERVER" = "true" ]; then
    MSA_FLAG="--use-msa-server"
fi

SA_KEY_FLAG=()
if [ -n "$GCS_SA_KEY_PATH" ]; then
    SA_KEY_FLAG=(--gcs-sa-key "$GCS_SA_KEY_PATH")
fi

python /opt/run_boltz2.py \
    --input-dir "$WORKDIR/inputs" \
    --output-dir "$WORKDIR/results" \
    --job-name "$JOB_NAME" \
    --recycling-steps "$RECYCLING_STEPS" \
    --diffusion-samples "$DIFFUSION_SAMPLES" \
    $MSA_FLAG \
    --gcs-bucket "$GCS_BUCKET" \
    "${SA_KEY_FLAG[@]}"

# Clean up credentials only if we created them
if [ -n "$GCS_SA_KEY_PATH" ]; then
    rm -f "$GCS_SA_KEY_PATH"
fi

echo "Done."
