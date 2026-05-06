FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/opt/miniforge/bin:${PATH}"
ENV BOLTZ_CACHE="/workspace/.boltz_cache"

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget ca-certificates git && \
    rm -rf /var/lib/apt/lists/*

# Install miniforge
RUN wget -qO /tmp/miniforge.sh https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh && \
    bash /tmp/miniforge.sh -b -p /opt/miniforge && \
    rm /tmp/miniforge.sh

# Create boltz2 environment
RUN conda create -n boltz2 python=3.12 pip -y && \
    conda clean -afy

# Install torch first, pinned to a CUDA build (cu124) matching the base image
# and the driver versions Vast.ai hosts typically ship (CUDA 12.4–12.8).
# Avoids pulling a torch wheel built for a CUDA toolkit newer than the host driver.
RUN /opt/miniforge/envs/boltz2/bin/pip install --no-cache-dir \
    --index-url https://download.pytorch.org/whl/cu124 \
    torch==2.5.1

# Install boltz2 + GCS client (uses the torch already installed above)
RUN /opt/miniforge/envs/boltz2/bin/pip install --no-cache-dir \
    boltz \
    google-cloud-storage

# Copy scripts
COPY run_boltz2.py /opt/run_boltz2.py
COPY entrypoint.sh /opt/entrypoint.sh
RUN chmod +x /opt/entrypoint.sh

WORKDIR /workspace

CMD ["/opt/entrypoint.sh"]
