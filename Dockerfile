# syntax=docker/dockerfile:1
#
# whisper-docker
# Batch subtitle generation via stable-ts (OpenAI Whisper).
#
# Base image: CUDA 12.1 runtime on Ubuntu 22.04.
# PyTorch detects GPU availability at runtime and falls back to CPU
# gracefully if no NVIDIA GPU / nvidia-container-toolkit is present.

FROM nvidia/cuda:12.1.0-base-ubuntu22.04

LABEL org.opencontainers.image.title="whisper-docker" \
      org.opencontainers.image.description="Batch SRT subtitle generation using stable-ts + Whisper" \
      org.opencontainers.image.source="https://github.com/rickytwarner/whisper-docker"

ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# System dependencies
#
# tini: lightweight init (PID 1) that correctly forwards signals (SIGTERM,
#       SIGINT) to the script and reaps zombie processes. Without it, Docker
#       stop/restart silently force-kills the container without cleanup.
# ---------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        python3 \
        python3-pip \
        inotify-tools \
        tini; \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Python dependencies — pinned for reproducible builds
#
# PyTorch is installed first from the CUDA 12.1 index so that stable-ts
# picks up the GPU-capable build. At runtime PyTorch falls back to CPU if
# no GPU is detected — no flag, rebuild, or image variant required.
# ---------------------------------------------------------------------------
RUN pip3 install --no-cache-dir \
        torch==2.5.1 \
        --index-url https://download.pytorch.org/whl/cu121

RUN pip3 install --no-cache-dir \
        stable-ts==2.19.1

# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------
WORKDIR /app
COPY whisper_batch.sh /app/whisper_batch.sh
RUN chmod +x /app/whisper_batch.sh

# ---------------------------------------------------------------------------
# Default environment (all overridable at runtime via -e / docker-compose)
# ---------------------------------------------------------------------------
ENV MEDIA_ROOT=/media \
    SCAN_DIRS="." \
    MODE=watch \
    SUBTITLE_STRATEGY=smart \
    WHISPER_LANGS="en" \
    STABLE_MODEL=medium \
    STABLE_TS_BIN=stable-ts \
    MODEL_DIR=/root/.cache/whisper \
    LOG_FILE=""

# /media                — mount your media library here at runtime
# /root/.cache/whisper  — mount a named volume here to persist model downloads
VOLUME ["/media", "/root/.cache/whisper"]

# ---------------------------------------------------------------------------
# Health check
#
# The script touches /tmp/.whisper_healthy on startup. If the file is absent,
# the container has crashed or failed to initialise.
# start-period gives the initial batch pass and model download time to run
# before health checks begin.
# ---------------------------------------------------------------------------
HEALTHCHECK \
    --interval=60s \
    --timeout=5s \
    --start-period=300s \
    --retries=3 \
    CMD test -f /tmp/.whisper_healthy || exit 1

# tini as PID 1: properly forwards SIGTERM → script and reaps zombies.
ENTRYPOINT ["/usr/bin/tini", "--", "/app/whisper_batch.sh"]
