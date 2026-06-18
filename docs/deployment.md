# 機器人部署指南 (Deployment Guide)

本文件指引 AI Agent 如何將對照表與通用模板結合，並調用部署腳本將機器人發布至 AWS ECS Fargate。

> [!NOTE]
> **當前測試與相容的環境版本 (Verified Environment & Versions)**
> * **ecsctl CLI 版本**: `0.6.0`
> * **yq CLI 版本**: `4.46.1`
> * **OpenAB 版本**: `0.8.5-beta.9`

---

## 📋 部署要素

部署流程涉及以下檔案：
1. **[bots.yaml](../ops/bots.yaml)**：Bot 專屬參數對照表。
2. **[openab-ecs.yaml.template](../ops/openab-ecs.yaml.template)**：通用服務模板。
3. **[deploy.sh](../ops/deploy.sh)**：自動化渲染與部署腳本（使用 yq 解析 YAML）。
4. **[validate.sh](../ops/validate.sh)**：部署前驗證腳本。
5. **[sync-hook-gists.sh](../ops/sync-hook-gists.sh)**：將 `hooks/` 中的 hook 腳本同步到 `bots.yaml` 設定的 gist，並刷新 SHA-256。
6. **[state_layers.md](./state_layers.md)**：狀態分層、本地目錄與 S3 路徑模型。

---

## ⚙️ Bot 設定檔對照 (`bots.yaml`)
每個 Bot 專屬的設定都應記錄在 [bots.yaml](../ops/bots.yaml) 中。例如 `ghost` 的設定：
```yaml
ghost:
  backend_agent: agy                           # 類型 (如 agy, codex)
  image: ghcr.io/openabdev/openab-antigravity:0.8.5-beta.9 # 映像檔
  agent_command: agy-acp                       # 執行指令
  secret_path: openab/oab-ghost                # Secrets Manager 的密鑰路徑
  cpu: '256'
  memory: '512'
  capacity: FARGATE_SPOT                       # FARGATE_SPOT (便宜但可能中斷) 或 FARGATE (穩定)
  state_bucket: ''                             # 備份狀態的 S3 bucket (選填，預設使用全域設定)
  pre_boot_url: 'https://gist.githubusercontent.com/...' # pre-boot 鉤子腳本網址
  pre_boot_sha256: 'f3898f7b...'               # 腳本的 SHA-256 雜湊值
  pre_shutdown_url: 'https://gist.githubusercontent.com/...' # pre-shutdown 鉤子腳本網址
  pre_shutdown_sha256: '66899a5e...'           # 腳本的 SHA-256 雜湊值
```

> [!IMPORTANT]
> `pre_boot_url` / `pre_shutdown_url` 在 deploy 時實際下載的是遠端 gist，不是 repo 內的 `hooks/*.sh`。
> 因此修改 [hooks/pre-boot.sh](../hooks/pre-boot.sh) 或 [hooks/pre-shutdown.sh](../hooks/pre-shutdown.sh) 後，必須先執行 `ops/sync-hook-gists.sh`，讓 gist 內容與 `bots.yaml` 的 SHA-256 一起更新。完整規範請見 [hooks_gist_sync.md](./hooks_gist_sync.md)。

## ⚙️ 機器人專屬人設與狀態同步 (Bot Personality & State)
目前採用 5-layer 模型，請以 [state_layers.md](./state_layers.md) 為唯一來源。

本地 repo 中可人工維護的靜態層全部位於 `state/layers/`：

1. `state/layers/2-common/`
2. `state/layers/3-backend/<backend>/`
3. `state/layers/4-bot/<bot>/`
4. `state/layers/5-agents/AGENTS.md`

任何上述靜態層修改後，請執行：
```bash
ops/upload-layers.sh <bot_name>
```

> `upload-layers.sh` 只會同步 Layer 2-5，不會覆蓋 Layer 1 runtime snapshot。

---

## 🚀 部署執行步驟

### Step 1. 驗證設定
在部署前，建議先驗證 `bots.yaml` 中所有 Bot 的設定是否合法：
```bash
ops/validate.sh
```
這會檢查：
- 所有必填欄位是否存在
- CPU/Memory 組合是否為 Fargate 合法值
- capacity 是否為 `FARGATE_SPOT` 或 `FARGATE`
- image 格式是否正確
- secret_path 格式是否合法
- pre_boot/pre_shutdown URL 是否為 HTTPS
- SHA-256 雜湊值格式是否正確

### Step 2. 確認環境
確保本地已生成 `aws-env.yaml` 且 `bots.yaml` 中定義了該 Bot 的參數。
執行以下指令確認：
```bash
cat ops/aws-env.yaml
```
應包含 `cluster`、`region`、`subnets`、`security_groups` 等欄位。

### Step 3. 驗證 Secrets
確保 `bots.yaml` 中設定的 `secret_path` 在 AWS 中已建立且寫入了 `DISCORD_BOT_TOKEN`。若 agent 需要使用 `gh`，可在同一個 Secret 內額外加入 `GH_TOKEN`；沒有設定也不會阻止服務啟動。
若使用可選的 `GH_TOKEN` 輔助腳本，請先確認 `state/layers/2-common/.openab/get-optional-gh-token.sh` 已經透過 `ops/upload-layers.sh <bot_name>` 同步到 S3，否則容器首次啟動時不會拿到這個共用檔案。

### Step 4. 執行部署
```bash
ops/deploy.sh <bot_name>
```
* **說明**：`deploy.sh` 會使用 yq 讀取 `aws-env.yaml`（全域環境）與 `bots.yaml`（Bot 參數），替換 `openab-ecs.yaml.template` 模板中的 `{{name}}`、`{{cluster}}`、`{{region}}`、`{{capacity}}` 等預留位置，產生一個臨時 YAML，並最終調用 `ecsctl apply -f <temp_yaml>` 套用部署。

### Step 5. 僅渲染（選填，用於調試）
若只想查看生成後的部署 YAML 內容，而不直接套用部署，執行：
```bash
ops/deploy.sh <bot_name> render
```
這會在目錄下產生 `.deploy-<bot_name>.yaml`。

---

## 🗑️ 退役 Bot

使用 `aws-destroy.sh` 停止 ECS 服務並清理相關資源：
```bash
ops/aws-destroy.sh <bot_name> [--purge-state] [--purge-secret]
```

選項：
- `--purge-state`：同時刪除 S3 中的狀態備份（不可逆）
- `--purge-secret`：同時刪除 AWS Secrets Manager 中的密鑰（不可逆）

清理流程：
1. 停止 ECS Service（將 desired count 設為 0，等待任務停止，然後刪除服務）
2. 刪除 CloudWatch Log Group
3. （選填）刪除 S3 狀態備份
4. （選填）刪除 Secrets Manager 密鑰
