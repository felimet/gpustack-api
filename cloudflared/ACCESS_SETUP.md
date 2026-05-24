# Cloudflare Zero Trust 設定指南

## 架構概覽

| Hostname | CF Access | 用途 |
|---|---|---|
| `sub-api.yourdomain.com` | Service Token | 程式化 API |
| `sub.yourdomain.com` | Email 白名單 | Web UI 管理員登入 |

**驗證分層：**
- CF Edge 負責 CF Access 驗證（Service Token / Email OAuth）
- cloudflared 不做 origin-level 再驗證（Public Hostname Additional Settings 不填 App）
- GPUStack 負責 API Key 驗證（Bearer token）

---

## 1. 建立 Tunnel

Zero Trust → Networks → Tunnels → **Create a tunnel**

- Connector type：**Cloudflared**
- Tunnel name：`gpustack-prod`
- 安裝方式：選 **Docker**，複製 token → 填入 `.env` 的 `CLOUDFLARE_TUNNEL_TOKEN`

### Public Hostnames（同一 Tunnel 設兩條）

| Subdomain | Domain | Path | Service | Additional Settings → Access |
|---|---|---|---|---|
| `sub-api` | `yourdomain.com` | （空） | `http://gpustack:80` | **不填（留空）** |
| `sub` | `yourdomain.com` | （空） | `http://gpustack:80` | 不填（Email 保護由 Application A 在 CF Edge 處理） |

> **關鍵**：Public Hostname 的 "Additional settings → Access" 欄位控制 cloudflared 的
> `originRequest.access.required`。若此欄位選了 Application，cloudflared 會在 QUIC 傳輸層
> 驗證 CF JWT，而 Service Token 的 JWT type（`"type":"service_token"`）會被靜默丟棄，
> CF edge 回傳 502，且無任何 HTTP 日誌可查。
>
> CF Access 的 edge-level 保護（Service Token 驗證）透過 Access Application 本身達成，
> 不需要 cloudflared 的 origin-level 再驗證。

---

## 2. 建立 Access Application

Zero Trust → Access → **Applications** → Add an application → **Self-hosted**

### Application A：Web UI（管理員用）

| 欄位 | 值 |
|---|---|
| Application name | `GPUStack UI` |
| Subdomain | `sub.yourdomain.com` |
| Path | （留空） |
| Session duration | `24h` |

**Policy：**
- Rule name：`Admin Email Whitelist`
- Action：`Allow`
- Include → Emails：填入允許的管理員 email 清單

---

### Application B：API（程式化存取）

| 欄位 | 值 |
|---|---|
| Application name | `GPUStack API` |
| Subdomain | `gpustack-ai.yourdomain.com` |
| Path | （留空） |
| Session duration | `24h` |

**Policy：**
- Rule name：`API Service Token`
- Action：`Allow`
- Include → Service Auth → **Service Token**（見步驟 3）

---

## 3. 建立 Service Token（API 用戶端憑證）

Zero Trust → Access → **Service Auth** → Service Tokens → **Create Service Token**

- Name：`gpustack-api-client`
- Token duration：依需求（建議 1 年或 No expiration）

複製產生的：
- `CF-Access-Client-Id`
- `CF-Access-Client-Secret`

---

## 4. GPUStack API Key 管理

Web UI → Settings → **API Keys** → Create API Key

---

## 5. 驗證

```bash
# API 端點需帶三個 header：CF-Access-Client-Id、CF-Access-Client-Secret、Authorization
curl -sf \
  -H "CF-Access-Client-Id: <client-id>" \
  -H "CF-Access-Client-Secret: <client-secret>" \
  -H "Authorization: Bearer <gpustack-api-key>" \
  https://sub-ai.yourdomain.com/v1/models | jq .

# Chat Completions
curl -s "https://sub-ai.yourdomain.com/v1/chat/completions" \
  -H "CF-Access-Client-Id: <client-id>" \
  -H "CF-Access-Client-Secret: <client-secret>" \
  -H "Authorization: Bearer <gpustack-api-key>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "<deployed-model-name>",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 100
  }' | jq .
```

```python
# OpenAI SDK 相容性測試
from openai import OpenAI

client = OpenAI(
    base_url="https://sub-api.yourdomain.com/v1",
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

## 安全說明

| 威脅 | 緩解措施 |
|---|---|
| 未授權 API 存取 | CF Access Service Token（第一關）+ GPUStack API Key（第二關） |
| 未授權 UI 存取 | Email whitelist，Cloudflare 負責 OAuth 流程 |
| DDoS | Cloudflare L7 防護，無需額外設定 |
| 主機防火牆 | 遠端機器只需 outbound 443（tunnel 連線），**不需開放 80 入站** |
| API Key 外洩 | CF Access Service Token 仍為第一關；另至 GPUStack Web UI 撤銷並重新產生 API Key |

---

## 故障排查：API 回傳 502

**根因**：Public Hostname 的 "Additional settings → Access" 欄位選了 Application
→ cloudflared `originRequest.access.required: true`
→ Service Token JWT 被 QUIC 層靜默丟棄，無 HTTP 日誌。

**確認**：
```bash
# debug log 中 API 請求完全沒有 HTTP request log（不像 Web UI 有正常日誌）
docker compose logs cloudflared --tail=50
```

**修正**：Zero Trust → Networks → Tunnels → 選 Tunnel → Public Hostnames →
編輯 `sub-api.yourdomain.com` → Additional settings → Access 欄位清空（不選 Application）→ Save。
等待約 30 秒 cloudflared 拉取新 config（版本號遞增）。
