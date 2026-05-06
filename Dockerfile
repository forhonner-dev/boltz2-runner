FROM nvidia/cuda:13.0.0-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/opt/miniforge/bin:${PATH}"
ENV BOLTZ_CACHE="/workspace/.boltz_cache"

# System deps. build-essential is needed at runtime: Triton (used by torch
# 2.11) JIT-compiles GPU kernels via a C compiler on first invocation, and
# crashes with "Failed to find C compiler" without one.
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget ca-certificates git build-essential && \
    rm -rf /var/lib/apt/lists/*

# Install miniforge
RUN wget -qO /tmp/miniforge.sh https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh && \
    bash /tmp/miniforge.sh -b -p /opt/miniforge && \
    rm /tmp/miniforge.sh

# Create boltz2 environment
RUN conda create -n boltz2 python=3.12 pip -y && \
    conda clean -afy

# Install boltz2 with [cuda] extra. As of boltz==2.2.1 + cuequivariance_torch
# 0.10, this resolves to torch 2.11+cu130, so the launcher must restrict offer
# search to hosts with cuda_vers>=13.0 (NVIDIA driver 565+).
RUN /opt/miniforge/envs/boltz2/bin/pip install --no-cache-dir \
    "boltz[cuda]" \
    google-cloud-storage

# Copy scripts
COPY run_boltz2.py /opt/run_boltz2.py
COPY entrypoint.sh /opt/entrypoint.sh
RUN chmod +x /opt/entrypoint.sh

WORKDIR /workspace

CMD ["/opt/entrypoint.sh"]
