# ds4 (DwarfStar / DeepSeek-V4-Flash) container image for NVIDIA aarch64 CUDA boxes
# with unified memory — built and tested on Jetson AGX Thor (sm_110), and intended to
# also work on DGX Spark (GB10, sm_121) by setting DS4_CUDA_ARCH.
#
# Design:
#   - Thin ubuntu:24.04 runtime; the ds4 binaries are prebuilt on the host (build.sh)
#     and copied in from ./bin — no CUDA toolkit is baked into the image.
#   - The CUDA runtime libs (libcudart/libcublas/libcublasLt) are bind-mounted from the
#     host at /usr/local/cuda (see docker-compose.yml), so the image always matches the
#     host toolkit and stays tiny.
#   - libcuda.so (the driver) is injected by the NVIDIA container runtime.
#   - Disk KV checkpoints persist to a host-mounted /kv-cache so a returning prompt can
#     reload its KV instead of a multi-minute cold re-prefill.
FROM ubuntu:24.04

# Build metadata (supplied by build.sh) so a regression can be attributed to ds4 vs the
# CUDA/container environment. Inspect with: docker inspect <image> | grep -A15 Labels
ARG DS4_GIT_COMMIT=unknown
ARG DS4_CUDA_VERSION=unknown
ARG DS4_CUDA_ARCH=sm_110
ARG DS4_MODEL_FILE=unknown
ARG DS4_MODEL_SIZE=unknown
ARG DS4_BUILD_DATE=unknown
LABEL org.opencontainers.image.title="ds4 (DeepSeek-V4-Flash) — aarch64 CUDA container" \
      org.opencontainers.image.source="https://github.com/antirez/ds4" \
      org.opencontainers.image.revision="${DS4_GIT_COMMIT}" \
      org.opencontainers.image.created="${DS4_BUILD_DATE}" \
      com.ds4.cuda_arch="${DS4_CUDA_ARCH}" \
      com.ds4.cuda="${DS4_CUDA_VERSION}" \
      com.ds4.model_file="${DS4_MODEL_FILE}" \
      com.ds4.model_size_bytes="${DS4_MODEL_SIZE}"

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/ds4
COPY bin/ds4 bin/ds4-server bin/ds4-bench bin/ds4-eval bin/ds4-agent ./
COPY bin/BUILD_INFO ./
RUN chmod +x ./ds4 ./ds4-server ./ds4-bench ./ds4-eval ./ds4-agent \
    && mkdir -p /models /kv-cache /logs

# CUDA runtime (bind-mounted at /usr/local/cuda) + NVIDIA-runtime driver injection.
# targets/sbsa-linux/lib covers Thor/Spark (SBSA) layouts; lib64 covers others.
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/cuda/targets/sbsa-linux/lib
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility

EXPOSE 8000

ENTRYPOINT ["/opt/ds4/ds4-server"]
# Sane default; docker-compose.yml overrides this with .env-driven values.
CMD ["--cuda", "--host", "0.0.0.0", "--port", "8000", "-c", "65536", \
     "-m", "/models/model.gguf", \
     "--kv-disk-dir", "/kv-cache", "--kv-disk-space-mb", "16384", \
     "--kv-cache-cold-max-tokens", "65000", "--kv-cache-reject-different-quant"]
