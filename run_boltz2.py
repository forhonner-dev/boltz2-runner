"""Run Boltz2 structure prediction and upload results to GCS."""
import argparse
import json
import subprocess
import time
from pathlib import Path

from google.cloud import storage


def run_prediction(input_dir, output_dir, recycling_steps=3, diffusion_samples=1, use_msa_server=False):
    """Run Boltz2 prediction on input YAML/FASTA files."""
    input_dir = Path(input_dir)
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    # Find input files
    input_files = (
        list(input_dir.glob("*.yaml"))
        + list(input_dir.glob("*.yml"))
        + list(input_dir.glob("*.fasta"))
    )
    if not input_files:
        raise FileNotFoundError(f"No .yaml/.yml/.fasta input files found in {input_dir}")

    results = {}
    for input_file in input_files:
        name = input_file.stem
        print(f"\n{'='*60}")
        print(f"Predicting: {name}")
        print(f"{'='*60}")

        cmd = [
            "boltz", "predict",
            str(input_file),
            "--out_dir", str(output_dir / name),
            "--recycling_steps", str(recycling_steps),
            "--diffusion_samples", str(diffusion_samples),
            "--output_format", "pdb",
            "--override",
        ]
        if use_msa_server:
            cmd.append("--use_msa_server")

        start = time.time()
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=7200)
            elapsed = time.time() - start

            if proc.returncode == 0:
                results[name] = {
                    "status": "success",
                    "elapsed_seconds": elapsed,
                    "output_dir": str(output_dir / name),
                }
                print(f"  Completed in {elapsed:.1f}s")
            else:
                results[name] = {
                    "status": "error",
                    "elapsed_seconds": elapsed,
                    "stderr": proc.stderr[-2000:] if proc.stderr else "",
                }
                print(f"  FAILED (exit {proc.returncode}): {proc.stderr[-500:]}")

            if proc.stdout:
                print(proc.stdout[-2000:])

        except subprocess.TimeoutExpired:
            elapsed = time.time() - start
            results[name] = {"status": "timeout", "elapsed_seconds": elapsed}
            print(f"  TIMEOUT after {elapsed:.1f}s")

    return results


def upload_results(output_dir, bucket_name, job_name, sa_key_path=None):
    """Upload all result files to GCS.

    Auth precedence:
      1. ``sa_key_path`` (explicit service-account JSON) — legacy path used by
         the Vast.AI launcher; pass via ``--gcs-sa-key`` or env var.
      2. Application Default Credentials — used automatically on GKE
         Workload Identity (the DiscoveryLedger production path) and any
         environment where ``GOOGLE_APPLICATION_CREDENTIALS`` is exported.
    """
    print(f"\nUploading results to gs://{bucket_name}/{job_name}/...")
    if sa_key_path:
        client = storage.Client.from_service_account_json(sa_key_path)
    else:
        client = storage.Client()
    bucket = client.bucket(bucket_name)

    output_dir = Path(output_dir)
    count = 0
    for f in output_dir.rglob("*"):
        if f.is_file():
            rel = f.relative_to(output_dir)
            blob = bucket.blob(f"{job_name}/{rel}")
            blob.upload_from_filename(str(f))
            count += 1

    print(f"  Uploaded {count} files")


def main():
    parser = argparse.ArgumentParser(description="Run Boltz2 structure prediction")
    parser.add_argument("--input-dir", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--job-name", required=True)
    parser.add_argument("--recycling-steps", type=int, default=3)
    parser.add_argument("--diffusion-samples", type=int, default=1)
    parser.add_argument("--use-msa-server", action="store_true")
    parser.add_argument("--gcs-bucket", required=True)
    # Optional: explicit service-account JSON path. Omit to use ADC
    # (Workload Identity on GKE, metadata server, GOOGLE_APPLICATION_CREDENTIALS).
    parser.add_argument("--gcs-sa-key", default=None)
    args = parser.parse_args()

    results = run_prediction(
        args.input_dir, args.output_dir,
        args.recycling_steps, args.diffusion_samples, args.use_msa_server,
    )

    # Save summary
    summary_path = Path(args.output_dir) / "summary.json"
    summary_path.write_text(json.dumps(results, indent=2))

    # Upload to GCS
    upload_results(args.output_dir, args.gcs_bucket, args.job_name, args.gcs_sa_key)

    # Print summary
    print(f"\n{'='*60}")
    print("SUMMARY")
    print(f"{'='*60}")
    for name, r in results.items():
        status = r["status"]
        elapsed = r.get("elapsed_seconds", 0)
        print(f"  {name}: {status} ({elapsed:.1f}s)")


if __name__ == "__main__":
    main()
