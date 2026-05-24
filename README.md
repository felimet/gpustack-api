# GPUStack 部署指南

單節點 LLM/VLM/Embedding/Rerank 推論服務，透過 Cloudflare Tunnel 對外暴露 API。

**版本：** GPUStack v2.1.2

---

## 架構總覽

```
外部用戶端
    │  HTTPS
    ▼
Cloudflare Edge
    ├─ sub-api.yourdomain.com  → CF Access Service Token（程式化 API）
    └─ sub.yourdomain.com     → CF Access Email 白名單（Web UI 管理）
    │
    ▼  Tunnel（outbound-only，主機不開入站埠）
cloudflared 容器（gpustack-net）
    │
    ▼  http://gpustack:80
gpustack 容器（server, 172.30.0.2）
    │  Web UI + Higress gateway
    ▼
gpustack-worker 容器（worker, 172.30.0.3）
    │  NVIDIA Runtime + docker.sock
    ▼
推論容器（llama.cpp / vLLM，由 GPUStack 動態產生）
    │  --network host，監聽 172.30.0.1:PORT
    ▼
硬體執行
```

**網路：** `gpustack-net` 172.30.0.0/24，gateway 固定 172.30.0.1  
**推論路由：** Higress → `worker_ip` 172.30.0.1:PORT → host-networked 推論容器

---

## 目錄結構

```
.
├── .env.example                 # 環境變數範本
├── .env                         # 實際密碼（已 gitignore）
├── .gitignore
├── docker-compose.yml           # 主堆疊（server + worker + cloudflared）
├── config/
│   ├── gpustack.yaml.example    # GPUStack server 設定範本
│   └── gpustack.yaml            # 實際設定（已 gitignore）
├── cloudflared/
│   └── ACCESS_SETUP.md          # Cloudflare Dashboard 操作步驟
└── scripts/
    ├── prereq.sh                # Fresh machine 前置安裝腳本
    ├── entrypoint-server.sh     # Server 容器初始化（worker_uuid）
    └── entrypoint-worker.sh     # Worker 容器初始化（worker_uuid + float<<20 patch）
```

---

## 部署流程

### 前提條件

- Docker Desktop
- NVIDIA 驅動
- Cloudflare 帳號，已建立 Tunnel

---

### 1. 前置依賴（fresh machine 才需要）

```bash
sudo bash scripts/prereq.sh
```

確認 GPU、安裝 Docker Engine、安裝 NVIDIA Container Toolkit、建立資料目錄。

---

### 2. 環境變數

```bash
cp .env.example .env
vim .env
```

| 變數 | 說明 |
|---|---|
| `GPUSTACK_BOOTSTRAP_PASSWORD` | 首次登入 admin 密碼 |
| `GPUSTACK_TOKEN` | Server/Worker 共用 Token（自訂字串） |
| `HUGGINGFACE_TOKEN` | HF token（下載 Gated 模型需要） |
| `CACHE_DIR` | 模型快取宿主機路徑（預設 `/opt/gpustack/cache`） |
| `CLOUDFLARE_TUNNEL_TOKEN` | Cloudflare Dashboard 複製的 Tunnel Token |

---

### 3. Cloudflare Tunnel

詳細步驟見 [`cloudflared/ACCESS_SETUP.md`](cloudflared/ACCESS_SETUP.md)。

1. Zero Trust → Tunnels → **Create a tunnel**（選 Cloudflared）
2. 複製 Token → 填入 `.env` `CLOUDFLARE_TUNNEL_TOKEN`
3. Public Hostname service URL：**`http://gpustack:80`**（容器名稱，非 localhost）

**雙 Hostname 策略：**

| Hostname | CF Access | 用途 |
|---|---|---|
| `sub-api.yourdomain.com` | Service Token | 程式化 API |
| `sub.yourdomain.com` | Email 白名單 | Web UI（管理員） |

> **關鍵**：`sub-ai` Public Hostname 的 "Additional settings → Access" 欄位**不填**任何 Application。
> CF Edge 負責 Service Token 驗證；cloudflared 不做 origin-level 再驗證（`access.required: false`）。
> 若此欄位有設定，cloudflared 會啟用 `originRequest.access.required: true`，Service Token JWT 被 QUIC 層靜默丟棄，CF edge 回傳 502。

---

### 4. GPUStack 設定

```bash
cp config/gpustack.yaml.example config/gpustack.yaml
```

Docker Desktop 本機部署不需修改：IP 已固定於 docker-compose（`172.30.0.2`），gateway 固定 `172.30.0.1`。

---

### 5. 啟動

```bash
docker compose up -d
docker compose logs -f gpustack
docker compose logs -f gpustack-worker
```

正常狀態（worker 等 server healthy 後才啟動）：

```
NAME                  STATUS
gpustack              healthy
gpustack-worker       running
gpustack-cloudflared  running
```

---

### 6. 驗證

**Web UI：**

```
http://localhost:8089
帳號：admin
密碼：.env 中的 GPUSTACK_BOOTSTRAP_PASSWORD
```

**API：**

```bash
curl -s http://localhost:8089/v1/models \
  -H "Authorization: Bearer <gpustack-api-key>" | jq .
```

**外網 API（透過 Cloudflare Tunnel）：**

```bash
curl -s "https://sub.yourdomain.com/v1/chat/completions" \
  -H "CF-Access-Client-Id: <client-id>.access" \
  -H "CF-Access-Client-Secret: <client-secret>" \
  -H "Authorization: Bearer <gpustack-api-key>" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3.5-0.8b-mtp-gguf","messages":[{"role":"user","content":"Hi"}],"max_tokens":50}'
```

**OpenAI SDK（透過 Cloudflare Tunnel）：**

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://sub.yourdomain.com/v1",
    api_key="<gpustack-api-key>",
    default_headers={
        "CF-Access-Client-Id": "<client-id>",
        "CF-Access-Client-Secret": "<client-secret>",
    },
)

resp = client.chat.completions.create(
    model="<deployed-model-name>",
    messages=[{"role": "user", "content": "Hello"}],
)
print(resp.choices[0].message.content)
```

---

## 部署模型

1. Web UI → Models → **Deploy Model**
2. 選擇來源（HuggingFace / Ollama / 本地路徑）

**4× RTX 3080 可用模型參考（~36 GB 合計）：**

| 模型 | 量化 | 預估 VRAM | 建議 GPU 數 |
|---|---|---|---|
| Llama-3.1-8B | FP16 | ~16 GB | 2 |
| Qwen2.5-14B | Q8 | ~15 GB | 2 |
| Qwen2.5-32B | Q4_K_M | ~20 GB | 2-3 |
| Qwen2-VL-7B | FP16 | ~15 GB | 2 |

---

## 維運

```bash
# 狀態
docker compose ps

# 日誌
docker compose logs -f gpustack
docker compose logs -f gpustack-worker
docker compose logs -f gpustack-cloudflared

# 重啟
docker compose restart gpustack
docker compose restart gpustack-worker

# 停止
docker compose down

# 停止並清除 volumes（資料庫重建）
docker compose down -v

# 更新版本
vim .env   # 修改 GPUSTACK_VERSION
docker compose pull && docker compose up -d
```

---

## 埠使用總覽

| 埠（宿主機） | 用途 | 外部可存取 |
|---|---|---|
| 8089 | Web UI + HTTP API | 本機直連；Tunnel 內部走 80 |
| 30080 | 內部 API（worker 連線） | 否 |
| 10150 | Worker 通訊 | 否 |
| 10151 | Worker metrics | 否 |
| 10161 | Server metrics | 否 |

推論容器使用 `--network host`，透過 bridge gateway `172.30.0.1` 路由，不映射宿主機埠。

---

## 故障排查

**GPU 無法偵測：**

```bash
docker exec gpustack-worker nvidia-smi
```

**模型 404 / no running instances：**

```bash
docker logs gpustack-worker 2>&1 | tail -30
docker ps | grep '\-run\-'   # 推論容器是否存在
docker exec gpustack curl -s http://172.30.0.1:<PORT>/health
```

**Tunnel 未連線：**

```bash
docker compose logs gpustack-cloudflared
# 確認 Public Hostname service URL 設為 http://gpustack:80
```

**模型 OOM：**

選用量化版本（Q4），或在 `docker-compose.yml` `gpustack-worker` command 加入 `--system-reserved-vram <GiB>`。

**VLM 圖片輸入報錯（image input is not supported）：**

GPUStack v2.1.2 下載 mmproj 後不自動傳給 llama.cpp。需手動加入 `backend_parameters`：

```bash
# 查 model id
curl -s http://localhost:8089/v2/models -u "admin:<PASSWORD>" \
  | python3 -c "import sys,json;[print(x['id'],x['name']) for x in json.load(sys.stdin)['items']]"

# 更新 backend_parameters
curl -s -X PUT "http://localhost:8089/v2/models/<MODEL_ID>" \
  -u "admin:<PASSWORD>" \
  -H "Content-Type: application/json" \
  -d '{
    "source": "local_path",
    "local_path": "<GGUF 檔案路徑>",
    "name": "<MODEL_NAME>",
    "backend": "llama.cpp",
    "backend_parameters": ["--mmproj <mmproj 完整路徑>"],
    "replicas": 1
  }'

# 刪除現有 instance 強制以新參數重啟
curl -s -X DELETE "http://localhost:8089/v2/model-instances/<INSTANCE_ID>" \
  -u "admin:<PASSWORD>"
```

mmproj 快取位置（container 內）：`/var/lib/gpustack/cache/huggingface/<ORG>/<REPO>/mmproj-F32.gguf`

Web UI 等效操作：Models → 編輯模型 → Backend Parameters 欄位加入 `--mmproj <路徑>`，儲存後刪除 instance 讓其重啟。

