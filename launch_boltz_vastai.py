"""Launch Boltz2 structure prediction jobs on Vast.ai.

Workflow:
  1. Upload input YAML files to GCS
  2. Search for GPU offers on Vast.ai
  3. Launch one instance per input

Usage:
    # Single prediction
    python launch_boltz_vastai.py \
        --input my_complex.yaml \
        --gcs-bucket boltz2-results \
        --gcs-sa-key path/to/key.json \
        --job-name my_complex

    # Batch: one job per YAML in a directory
    python launch_boltz_vastai.py \
        --input inputs/ \
        --gcs-bucket boltz2-results \
        --gcs-sa-key path/to/key.json \
        --batch
"""
import argparse
import base64
import json
import os
import subprocess
from pathlib import Path

from google.cloud import storage


DOCKER_IMAGE = "ghcr.io/forhonner-dev/boltz2-runner:latest"
DISK_GB = 60


def upload_input_to_gcs(bucket_name, sa_key_path, prefix, input_path):
    """Upload input file to GCS under prefix."""
    client = storage.Client.from_service_account_json(sa_key_path)
    bucket = client.bucket(bucket_name)

    blob = bucket.blob(f"{prefix}/{Path(input_path).name}")
    blob.upload_from_filename(input_path)
    print(f"  Uploaded input to gs://{bucket_name}/{prefix}/")


def encode_file_b64(path):
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode()


def search_offers(min_gpu_ram=24, max_price=0.40, min_reliability=0.95):
    """Search for suitable GPU offers."""
    query = (
        f"gpu_ram>={min_gpu_ram} "
        f"dph<={max_price} "
        f"reliability>={min_reliability} "
        f"cuda_vers>=12.0 "
        f"rentable=true "
        f"num_gpus=1"
    )
    result = subprocess.run(
        ["vastai", "search", "offers", query, "-o", "dph+", "--raw"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"Error searching offers: {result.stderr}")
        return []

    offers = json.loads(result.stdout)
    return offers


def create_instance(offer_id, gcs_bucket, gcs_input_prefix, gcs_sa_key_b64, job_name,
                    recycling_steps=3, diffusion_samples=1, use_msa_server=False):
    """Create a Vast.ai instance to run Boltz2."""
    env_str = (
        f"-e GCS_BUCKET={gcs_bucket} "
        f"-e GCS_INPUT_PREFIX={gcs_input_prefix} "
        f"-e GCS_SA_KEY_B64={gcs_sa_key_b64} "
        f"-e JOB_NAME={job_name} "
        f"-e RECYCLING_STEPS={recycling_steps} "
        f"-e DIFFUSION_SAMPLES={diffusion_samples} "
        f"-e USE_MSA_SERVER={'true' if use_msa_server else 'false'}"
    )

    result = subprocess.run(
        [
            "vastai", "create", "instance", str(offer_id),
            "--image", DOCKER_IMAGE,
            "--disk", str(DISK_GB),
            "--env", env_str,
            "--onstart-cmd", "/opt/entrypoint.sh",
            "--raw",
        ],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"  Error creating instance: {result.stderr}")
        return None

    instance = json.loads(result.stdout)
    instance_id = instance.get("new_contract")
    print(f"  Launched: {job_name} -> Vast.ai instance {instance_id}")
    return instance_id


def main():
    parser = argparse.ArgumentParser(description="Launch Boltz2 jobs on Vast.ai")
    parser.add_argument("--input", required=True, help="YAML file or directory of YAML files")
    parser.add_argument("--gcs-bucket", default="boltz2-results", help="GCS bucket name")
    parser.add_argument("--gcs-sa-key", required=True, help="Path to GCS service account JSON key")
    parser.add_argument("--job-name", help="Job name (ignored in batch mode)")
    parser.add_argument("--batch", action="store_true", help="One job per YAML file in directory")
    parser.add_argument("--recycling-steps", type=int, default=3)
    parser.add_argument("--diffusion-samples", type=int, default=1)
    parser.add_argument("--use-msa-server", action="store_true")
    parser.add_argument("--max-price", type=float, default=0.40, help="Max $/hr per GPU")
    parser.add_argument("--min-gpu-ram", type=int, default=24, help="Min GPU RAM in GB")
    args = parser.parse_args()

    gcs_sa_key_b64 = encode_file_b64(args.gcs_sa_key)
    input_path = Path(args.input)

    # Collect input files
    if args.batch or input_path.is_dir():
        yamls = list(input_path.glob("*.yaml")) + list(input_path.glob("*.yml"))
        if not yamls:
            print(f"No YAML files found in {input_path}")
            return
        jobs = [(y.stem, str(y)) for y in yamls]
    else:
        job_name = args.job_name or input_path.stem
        jobs = [(job_name, str(input_path))]

    # Search for offers
    print("Searching for GPU offers...")
    offers = search_offers(min_gpu_ram=args.min_gpu_ram, max_price=args.max_price)
    if not offers:
        print("No suitable offers found. Try increasing --max-price or decreasing --min-gpu-ram")
        return
    print(f"Found {len(offers)} offers, cheapest: ${offers[0]['dph_total']:.3f}/hr")

    if len(jobs) > len(offers):
        print(f"Warning: {len(jobs)} jobs but only {len(offers)} offers available")

    # Launch jobs
    instances = []
    for i, (name, yaml_path) in enumerate(jobs):
        offer = offers[i % len(offers)]
        offer_id = offer["id"]
        input_prefix = f"inputs/{name}"

        print(f"\n[{i+1}/{len(jobs)}] {name} -> offer {offer_id} (${offer['dph_total']:.3f}/hr)")

        upload_input_to_gcs(args.gcs_bucket, args.gcs_sa_key, input_prefix, yaml_path)

        instance_id = create_instance(
            offer_id, args.gcs_bucket, input_prefix,
            gcs_sa_key_b64, name,
            args.recycling_steps, args.diffusion_samples, args.use_msa_server,
        )
        if instance_id:
            instances.append({"name": name, "instance_id": instance_id, "offer_id": offer_id})

    # Summary
    print(f"\n{'='*60}")
    print(f"Launched {len(instances)} instances")
    for inst in instances:
        print(f"  {inst['name']}: instance {inst['instance_id']}")
    print(f"\nMonitor: vastai show instances")
    print(f"Logs:    vastai logs <instance_id>")
    print(f"Results: gs://{args.gcs_bucket}/<job_name>/")
    print(f"\nInstances will auto-upload results to GCS when done.")
    print(f"Remember to destroy instances after completion:")
    print(f"  vastai destroy instance <instance_id>")


if __name__ == "__main__":
    main()
