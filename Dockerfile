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

# Install boltz2 + GCS client
RUN /opt/miniforge/envs/boltz2/bin/pip install --no-cache-dir \
    "boltz[cuda]" \
    google-cloud-storage

# Copy scripts
COPY run_boltz2.py /opt/run_boltz2.py
COPY entrypoint.sh /opt/entrypoint.sh
RUN chmod +x /opt/entrypoint.sh

WORKDIR /workspace

CMD ["/opt/entrypoint.sh"]
