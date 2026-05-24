#!/bin/sh
# GPUStack worker 容器初始化
# 1. worker_uuid：WSL2 無 DMI，預先建立避免 RuntimeError
# 2. float<<20 patch：WSL2 NVML 回傳 float，需轉 int 才能位移
set -e

DATA=/var/lib/gpustack
mkdir -p "$DATA"

if [ ! -f "$DATA/worker_uuid" ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || \
           python3 -c "import uuid; print(uuid.uuid4())")
    printf '%s' "$UUID" > "$DATA/worker_uuid"
    echo "[gpustack-init] Generated worker_uuid: $UUID"
else
    echo "[gpustack-init] worker_uuid exists: $(cat "$DATA/worker_uuid")"
fi

RUNTIME_PY=$(python3 -c \
    "import gpustack.detectors.runtime.runtime as m; print(m.__file__)" 2>/dev/null || true)
if [ -n "$RUNTIME_PY" ] && grep -q "dev\.memory << 20" "$RUNTIME_PY" 2>/dev/null; then
    sed -i \
        's/dev\.memory << 20/int(dev.memory) << 20/g;
         s/dev\.memory_used << 20/int(dev.memory_used) << 20/g' \
        "$RUNTIME_PY"
    echo "[gpustack-init] Patched float<<int in $RUNTIME_PY"
else
    echo "[gpustack-init] runtime.py already patched or not found"
fi

exec /usr/bin/entrypoint.sh "$@"
