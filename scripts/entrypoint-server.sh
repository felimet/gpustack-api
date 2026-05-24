#!/bin/sh
# GPUStack server 容器初始化
# WSL2 無 /sys/class/dmi/id/product_uuid，需預先建立 worker_uuid 檔案
# 預寫 token 檔案以覆蓋 GPUStack 自動生成行為
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

if [ -n "$GPUSTACK_TOKEN" ] && [ ! -f "$DATA/token" ]; then
    printf '%s' "$GPUSTACK_TOKEN" > "$DATA/token"
    echo "[gpustack-init] Pre-set token file from GPUSTACK_TOKEN"
elif [ -f "$DATA/token" ]; then
    echo "[gpustack-init] token file exists: $(cat "$DATA/token")"
fi

exec /usr/bin/entrypoint.sh "$@"
