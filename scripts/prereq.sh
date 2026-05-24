#!/usr/bin/env bash
# =============================================================================
# prereq.sh — 前置依賴安裝腳本
# 支援：Ubuntu 22.04 / 24.04（含 WSL2）+ NVIDIA GPU
# 執行：bash scripts/prereq.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 0. 確認 root ──────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "請以 root 或 sudo 執行此腳本"

# ── 偵測 WSL2 ─────────────────────────────────────────────────────────────────
IS_WSL=false
if grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=true
    info "偵測到 WSL2 環境"
fi

# ── 1. 確認 NVIDIA GPU 可存取 ─────────────────────────────────────────────────
info "檢查 NVIDIA GPU..."

if $IS_WSL; then
    # WSL2：驅動由 Windows 透傳，nvidia-smi 位於 /usr/lib/wsl/lib/
    export PATH="/usr/lib/wsl/lib:$PATH"
    if ! command -v nvidia-smi &>/dev/null; then
        error "nvidia-smi 未找到。WSL2 需要：
  1. Windows 主機已安裝 NVIDIA 驅動（Windows 11 已確認）
  2. WSL2 GPU 透傳預設啟用，請重新開啟 WSL2 終端後再試。"
    fi
else
    if ! command -v nvidia-smi &>/dev/null; then
        error "nvidia-smi 未找到。請先安裝 NVIDIA 驅動（建議 535+）後再執行此腳本。"
    fi
fi

nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
info "NVIDIA GPU OK"

# ── 2. 安裝 Docker Engine ──────────────────────────────────────────────────────
info "檢查 Docker..."

if $IS_WSL && [ -S /var/run/docker.sock ] && docker info &>/dev/null 2>&1; then
    # Docker Desktop WSL Integration socket 掛載 → 警告
    if docker info 2>/dev/null | grep -q "Docker Desktop"; then
        warn "偵測到 Docker Desktop。建議改用 Docker Engine 直接安裝於 WSL2 內部"
        warn "Docker Desktop 的 host networking 在 WSL2 行為異於原生 Linux"
    fi
fi

if ! command -v docker &>/dev/null || ! docker info &>/dev/null 2>&1; then
    info "安裝 Docker Engine..."
    apt-get update -q
    apt-get install -y -q ca-certificates curl gnupg lsb-release

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -q
    apt-get install -y -q docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    if $IS_WSL; then
        # WSL2 預設無 systemd，以 service 啟動
        service docker start || true
        systemctl enable docker 2>/dev/null || true
    else
        systemctl enable --now docker
    fi
    info "Docker Engine 安裝完成"
else
    DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
    info "Docker 已安裝：${DOCKER_VERSION}"
fi

# ── 3. 安裝 NVIDIA Container Toolkit ──────────────────────────────────────────
info "檢查 NVIDIA Container Toolkit..."
if ! dpkg -l | grep -q nvidia-container-toolkit 2>/dev/null; then
    info "安裝 NVIDIA Container Toolkit..."

    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor \
        | tee /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg > /dev/null

    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt-get update -q
    apt-get install -y -q nvidia-container-toolkit

    if $IS_WSL; then
        # WSL2 + Docker Desktop：daemon 在 Windows Hyper-V VM 內，
        # nvidia-ctk 寫入的 /etc/docker/daemon.json 不被 Docker Desktop 讀取。
        # Docker Desktop 已內建 NVIDIA 支援，不需要修改 daemon 設定。
        info "WSL2 + Docker Desktop：跳過 daemon.json 設定（Docker Desktop 已內建 NVIDIA 支援）"
    else
        nvidia-ctk runtime configure --runtime=docker
        systemctl restart docker
    fi

    info "NVIDIA Container Toolkit 安裝完成"
else
    info "NVIDIA Container Toolkit 已安裝"
fi

# ── 4. 驗證 GPU 可通過 Docker 存取 ────────────────────────────────────────────
# 選用與主機 Ubuntu 版本對應的 CUDA base 映像（僅含 nvidia-smi，不需完整 CUDA）
info "驗證 Docker GPU 存取..."
CUDA_VALIDATE_IMAGE="nvidia/cuda:12.9.2-base-ubuntu24.04"
info "驗證映像：${CUDA_VALIDATE_IMAGE}"

if docker run --rm --runtime=nvidia --gpus all \
    "${CUDA_VALIDATE_IMAGE}" nvidia-smi -L 2>/dev/null; then
    info "GPU 通過 Docker 存取驗證 OK"
else
    warn "GPU Docker 驗證失敗，請檢查 NVIDIA Container Toolkit 設定"
    if $IS_WSL; then
        warn "WSL2 常見解法：PowerShell 執行 'wsl --shutdown'，重開 WSL2 後再試"
    fi
fi

# ── 5. 建立資料目錄 ────────────────────────────────────────────────────────────
info "建立資料目錄..."
DATA_DIR="${DATA_DIR:-/opt/gpustack/data}"
CACHE_DIR="${CACHE_DIR:-/opt/gpustack/cache}"
LOG_DIR="${LOG_DIR:-/opt/gpustack/logs}"

mkdir -p "$DATA_DIR" "$CACHE_DIR" "$LOG_DIR"
chmod 755 "$DATA_DIR" "$CACHE_DIR" "$LOG_DIR"
info "資料目錄：$DATA_DIR"
info "快取目錄：$CACHE_DIR（模型權重，預計需要 500GB+）"

if $IS_WSL; then
    warn "快取目錄應在 WSL2 內部（/opt/...），不要放在 /mnt/c、/mnt/d 等 Windows 掛載路徑（I/O 效能差 10x+）"
fi

# ── 6. 防火牆（WSL2 通常不啟用 ufw）──────────────────────────────────────────
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    info "設定 UFW 規則..."
    ufw allow 80/tcp comment 'GPUStack Web UI'
    ufw allow 30080/tcp comment 'GPUStack Internal API'
    ufw allow 10150/tcp comment 'GPUStack Worker'
    ufw allow 10151/tcp comment 'GPUStack Worker Metrics'
    ufw allow 10161/tcp comment 'GPUStack Server Metrics'
    ufw allow 40000:40063/tcp comment 'GPUStack Model Services'
    ufw allow 41000:41999/tcp comment 'GPUStack Ray'
    info "UFW 規則設定完成"
fi

# ── 7. 完成 ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}前置依賴安裝完成！${NC}"
if $IS_WSL; then
    echo -e "${YELLOW}WSL2 環境：服務啟動後透過 http://localhost 存取（Windows 自動轉發）${NC}"
fi
echo -e "${GREEN}====================================================${NC}"
echo ""
echo "下一步："
echo "  1. cd <gpustack-repo-dir>"
echo "  2. cp .env.example .env && vim .env"
echo "  3. cp config/gpustack.yaml.example config/gpustack.yaml && vim config/gpustack.yaml"
echo "  4. docker compose up -d"
if $IS_WSL; then
    echo "  5. 開啟瀏覽器：http://localhost"
else
    echo "  5. 開啟瀏覽器：http://$(hostname -I | awk '{print $1}')"
fi
echo ""
