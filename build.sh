#!/usr/bin/env bash
# Build ds4 for your GPU arch (from your ds4 clone) and package the image.
# Run on the host (needs nvcc). Config comes from .env.
#   ./build.sh          build binaries + image
#   ./build.sh --hash   also compute the model sha256 (slow for big models)
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { echo "ERROR: no .env — cp .env.example .env and edit it." >&2; exit 1; }
set -a; . ./.env; set +a
: "${DS4_SRC:?set DS4_SRC (your antirez/ds4 clone) in .env}"
: "${DS4_CUDA_ARCH:=sm_110}"
[ -d "$DS4_SRC" ] || { echo "ERROR: DS4_SRC '$DS4_SRC' not found" >&2; exit 1; }

# Build binaries for the chosen arch.
( cd "$DS4_SRC" && make cuda CUDA_ARCH="$DS4_CUDA_ARCH" -j"$(nproc)" )

# Verify native SASS. Read into a var first: `cuobjdump | grep -q` under pipefail races
# on SIGPIPE (grep exits early -> cuobjdump 141 -> false failure).
ARCH_LINES=$(cuobjdump "$DS4_SRC/ds4-server" 2>/dev/null | grep -i 'arch *=' || true)
case "$ARCH_LINES" in
    *"$DS4_CUDA_ARCH"*) echo "OK: $DS4_CUDA_ARCH SASS present" ;;
    *) echo "ERROR: $DS4_CUDA_ARCH SASS not found (got: '${ARCH_LINES:-none}')" >&2; exit 1 ;;
esac

# Stage binaries into the build context.
mkdir -p bin "${KV_DIR:-./kv-cache}" "${LOG_DIR:-./logs}"
cp -f "$DS4_SRC"/ds4 "$DS4_SRC"/ds4-server "$DS4_SRC"/ds4-bench "$DS4_SRC"/ds4-eval "$DS4_SRC"/ds4-agent bin/

# Build metadata -> BUILD_INFO + OCI labels.
GIT_COMMIT=$(git -C "$DS4_SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)
CUDA_VERSION=$(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9.]*\).*/\1/p' | head -1); [ -z "$CUDA_VERSION" ] && CUDA_VERSION=unknown
MODEL_FILE=$(basename "${MODEL_PATH:-unknown}")
MODEL_SIZE=$(stat -c%s "${MODEL_PATH:-/nonexistent}" 2>/dev/null || echo 0)
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MODEL_SHA="(skipped; run ./build.sh --hash)"
if [ "${1:-}" = "--hash" ] && [ -f "${MODEL_PATH:-}" ]; then
    echo "Hashing model..."; MODEL_SHA=$(sha256sum "$MODEL_PATH" | awk '{print $1}')
fi
cat > bin/BUILD_INFO <<EOF
ds4_git_commit: $GIT_COMMIT
build_date:     $BUILD_DATE
cuda_version:   $CUDA_VERSION
cuda_arch:      $DS4_CUDA_ARCH
model_file:     $MODEL_FILE
model_size:     $MODEL_SIZE bytes
model_sha256:   $MODEL_SHA
context_size:   ${DS4_CTX:-65536}
EOF

export DS4_GIT_COMMIT="$GIT_COMMIT" DS4_CUDA_VERSION="$CUDA_VERSION" DS4_CUDA_ARCH="$DS4_CUDA_ARCH" \
       DS4_MODEL_FILE="$MODEL_FILE" DS4_MODEL_SIZE="$MODEL_SIZE" DS4_BUILD_DATE="$BUILD_DATE"
docker compose build
echo "Built ds4-thor:local. Start with: docker compose up -d"
