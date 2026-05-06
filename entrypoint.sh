#!/bin/bash
set -euo pipefail

source /opt/miniforge/bin/activate boltz2

# --- Configuration from environment variables ---
# Required:
#   GCS_BUCKET       - GCS bucket name
#   GCS_SA_KEY_B64   - base64-encoded GCS service account JSON key
#   GCS_INPUT_PREFIX - GCS prefix for inputs
#   JOB_NAME         - name for this job
# Optional:
#   RECYCLING_STEPS   - recycling iterations (default: 3)
#   DIFFUSION_SAMPLES - number of structure samples (default: 1)
#   USE_MSA_SERVER    - set to "true" to use mmseqs2 MSA server

WORKDIR="/workspace/boltz2_run"
mkdir -p "$WORKDIR/inputs" "$WORKDIR/results" "$BOLTZ_CACHE"

# Set up GCS credentials
echo "$GCS_SA_KEY_B64" | base64 -d > /tmp/gcs_key.json
export GOOGLE_APPLICATION_CREDENTIALS=/tmp/gcs_key.json

# Download model weights on first run
echo "Ensuring model weights are cached..."
boltz predict --help > /dev/null 2>&1 || true

# Download inputs from GCS
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

python /opt/run_boltz2.py \
    --input-dir "$WORKDIR/inputs" \
    --output-dir "$WORKDIR/results" \
    --job-name "$JOB_NAME" \
    --recycling-steps "$RECYCLING_STEPS" \
    --diffusion-samples "$DIFFUSION_SAMPLES" \
    $MSA_FLAG \
    --gcs-bucket "$GCS_BUCKET" \
    --gcs-sa-key /tmp/gcs_key.json

# Clean up credentials
rm -f /tmp/gcs_key.json

echo "Done."
