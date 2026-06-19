# OpenAB ECS Deployments (oab-ecs)

這個儲存庫用於管理與部署 OpenAB 機器人服務至 AWS ECS Fargate。我們採用了「部署架構模板」與「Bot 實例參數」分離的架構，使得管理多個不同類型的 Bot 變得更簡單、乾淨。

---

## 📋 前置需求 (Prerequisites)

在開始使用本儲存庫進行部署之前，請確保您的環境中已安裝並設定好以下工具：

> [!TIP]
> **給 AI Agent 的一鍵安裝提示詞**
> 如果您正在使用 AI Coding Agent，可以複製以下提示詞，讓它自動幫您安裝所需的環境工具：
> ```text
> help me install aws cli , session-manager-plugin and ecsctl per https://github.com/oablab/ecsctl ,
>   if already installed. skip
> ```

1. **AWS CLI**：用於與 AWS 進行身份驗證與 API 互動。
   * [官方安裝指南](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
2. **AWS Session Manager Plugin**：使 `ecsctl exec` 能夠進入容器內執行指令的必要插件。
   * [官方安裝指南](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
3. **ecsctl** (0.6.0+)：Kubectl 風格的 ECS Fargate 管理 CLI。
   * [GitHub 倉庫連結](https://github.com/oablab/ecsctl)
4. **yq** (v4+)：YAML 檔案解析工具，用於讀取設定檔。
   * [GitHub 倉庫連結](https://github.com/mikefarah/yq)
5. **jq** (1.6+)：JSON 處理工具，用於 AWS CLI 輸出解析。
   * [官方安裝指南](https://stedolan.github.io/jq/download/)

> [!NOTE]
> **當前測試與相容的環境版本 (Verified Environment & Versions)**
> * **ecsctl CLI 版本**: `0.6.0`
> * **yq CLI 版本**: `4.46.1`
> * **OpenAB 版本**: `0.8.5-beta.9`

---

## 📂 目錄結構

* [docs/](./docs) - 相關維運與 AI Agent 指引文件：
* [hooks/](./hooks) - 容器啟動與關閉的鉤子腳本目錄，包含 [pre-boot.sh](./hooks/pre-boot.sh) 與 [pre-shutdown.sh](./hooks/pre-shutdown.sh)
* [state/](./state) - 本地靜態 overlay layers 目錄，對應 Layer 2-5（Layer 1 runtime 不落在 repo）
* [ops/](./ops) - 維運相關腳本與設定目錄：
* `restored/` - (Git 忽略) 本地測試下載還原之機器人狀態暫存目錄

---

## 🛠️ 運作機制

### 架構圖 (Architecture)

```text
                     +------------------+
                     | Local Developer  |
                     +--------+---------+
                              | 1. ecsctl apply
                              v
                   +--------------------+
     +-------------+  AWS ECS Fargate   +-------------+
     |             | (OpenAB Container) |             |
     |             +--------+-----------+             |
     |                      |                         |
     | 2. Get Token         | 3. Sync State           | 4. Write Logs
     | (via Task Role)      | (via Task Role)         |
     v                      v                         v
+-----------+          +-----------+          +---------------+
|    AWS    |          |   AWS     |          |      AWS      |
|  Secrets  |          |    S3     |          |  CloudWatch   |
|  Manager  |          |  Bucket   |          |     Logs      |
+-----------+          +-----------+          +---------------+
```

### 1. 設定檔分離機制
我們將設定分為兩個檔案，以實現環境與實例的解耦：
* **[bots.yaml](./ops/bots.yaml)**：僅包含機器人專屬的配置（如 image、secret_path、capacity 等），可安全地提交至 Git。
* **`ops/aws-env.yaml`**：包含您專屬的 AWS 帳號與網路架構參數（如 subnets, security_groups, cluster, region 等）。此檔案由 [aws-init.sh](./ops/aws-init.sh) 自動生成，並已設定於 `.gitignore` 中，不會被提交。

#### bots.yaml 內容範例：
```yaml
ghost:
  backend_agent: agy                           # Agent 類型 (如 agy, codex)
  image: ghcr.io/openabdev/openab-antigravity:0.8.5-beta.9
  agent_command: agy-acp                       # 啟動指令
  secret_path: openab/oab-ghost                # AWS Secrets Manager Secret ID
  cpu: '256'
  memory: '512'
  capacity: FARGATE_SPOT                       # FARGATE_SPOT (便宜但可能中斷) 或 FARGATE (穩定)
  state_bucket: ''                             # 狀態備份的 S3 Bucket (選填，預設使用全域設定)
  pre_boot_url: 'https://gist.githubusercontent.com/...'
  pre_boot_sha256: 'f3898f7b...'
  pre_shutdown_url: 'https://gist.githubusercontent.com/...'
  pre_shutdown_sha256: '66899a5e...'
```

### 2. 通用模板 (`openab-ecs.yaml.template`)
定義了標準的 `ecsctl` Fargate Service 設定，包含：
* 動態設定的 Service Name: `openab-{{name}}-service`
* 動態帶入的容器映像檔與環境變數
* 可配置的 `capacity`（FARGATE_SPOT 或 FARGATE）
* 可配置的 `region`（從 aws-env.yaml 讀取）
* 在 `config.toml` 中動態載入的 AWS Secrets Manager 參考 `aws-sm://{{secret_path}}#DISCORD_BOT_TOKEN`
* 整合了 `pre_boot` 與 `pre_shutdown` 鉤子，在容器啟動前載入檔案，並在容器關閉前自動備份到 S3。

### 3. 狀態與人設管理機制 (S3 State & Layering)
當 Bot 容器啟動時，會執行開機鉤子 (`pre-boot.sh`) 來還原與同步狀態。完整模型請見 [state_layers.md](./docs/state_layers.md)。其載入順序為：

1. **Layer 1：runtime snapshot** (`s3://<bucket>/runtime/<bot>/home.tar.gz`)
2. **Layer 2：全域共用靜態資源** (`s3://<bucket>/layers/2-common/`)
3. **Layer 3：backend 共用靜態資源** (`s3://<bucket>/layers/3-backend/<backend>/`)
4. **Layer 4：bot 專屬靜態資源** (`s3://<bucket>/layers/4-bot/<bot>/`)
5. **Layer 5：共用 AGENTS.md** (`s3://<bucket>/layers/5-agents/AGENTS.md`)

#### 📌 如何設定「專屬人設」與「工具說明」？
* **全域共用維運規則**：請編輯 `state/layers/5-agents/AGENTS.md`。
* **個別 Bot 專屬人設**：請建立於 `state/layers/4-bot/<bot>/` 下（例如 `state/layers/4-bot/ghost/steering/Identity.md`）。
* **共用工具說明**：請編輯 `state/layers/2-common/TOOLS.md`。

### 4. 工具快取與下載機制
為了加速容器啟動並確保冷啟動時的認證穩定性：
* **`uv` (Python 包管理器)**：優先從 S3 快取路徑 `cache/uv-0.11.21-x86_64-unknown-linux-musl.tar.gz` 獲取，若不存在則下載固定版本 `0.11.21`，並先以官方提供的 `sha256` 檢查再安裝。
* **`aws` (AWS CLI)**：每次容器啟動時，直接下載固定版本 `2.35.7` 再解壓縮安裝，避免 `latest` 帶來的啟動漂移。

---

## 📋 部署 SOP 與指令範例

### 前置作業：初始化環境
如果您需要自訂自動建立的 AWS 資源名稱或明確指定 VPC / subnet，可以先編輯 [aws-init.yaml](./ops/aws-init.yaml)。
接著，請確保您已經在本機執行 `aws configure` 完成憑證設定，然後執行初始化腳本：
```bash
ops/aws-init.sh
```
這會自動根據設定檔中的名稱去探測/建立對應的 ECS、IAM、VPC 設定，並產生 `ops/aws-env.yaml` 檔案。
如果 `aws-init.yaml` 內有填 `vpc_id` 或 `subnet_ids`，腳本會優先採用這些覆寫值，不再完全依賴自動探測。

### 1. 驗證設定
在部署前，建議先驗證 `bots.yaml` 中所有 Bot 的設定是否合法：
```bash
ops/validate.sh
```
這會檢查必填欄位、CPU/Memory 組合、capacity 值、image 格式等，並提示解決方案。

### 2. 部署 Bot
使用自動化部署腳本：
```bash
ops/deploy.sh <bot名稱>
```
例如：
```bash
ops/deploy.sh ghost
```

### 3. 僅渲染 YAML（不部署）
如果您只想查看替換後的部署 YAML 檔（用於檢查或手動部署），可加上 `render` 參數：
```bash
ops/deploy.sh ghost render
```
這會在目錄下產生一個 `.deploy-ghost.yaml` 檔案，而不會呼叫 `ecsctl`。

### 4. 查詢服務狀態
執行以下指令可立即顯示 Bot 的運作情形，並印出最近 15 筆 CloudWatch 日誌：
```bash
ops/status.sh ghost
```

### 5. 進入容器進行身分認證 (重要)
如果您的 Bot (例如 Antigravity 等) 在部署後需要手動執行認證登入 (如 `agy auth` 或 `huggingface-cli login`)，請遵循以下步驟進行。

> [!WARNING]
> **身分權限問題**：
> 透過 `ecsctl exec` 進入容器時，預設身分是 `root`。如果在 `root` 身分下執行登入，產生的憑證檔案將會屬於 `root`，導致以 `agent` 身分運行的背景機器人服務因為權限不足 (Permission Denied) 而無法讀取 Token。
> 因此，**請務必在切換為 `agent` 使用者後再執行登入**。

**操作步驟：**

1. **進入容器**（使用服務別名 `openab-<bot名稱>`）：
   ```bash
   ecsctl exec openab-ghost bash
   ```
2. **切換為 `agent` 使用者**（此時會自動載入我們預置的登入別名）：
   ```bash
   su - agent
   ```
3. **執行登入指令**：
   我們在環境中預置了 `agentauth` 別名，您可直接呼叫：
   ```bash
   agentauth
   ```
   *(這會自動執行對應的登入指令，例如 `agy auth`，且所有憑證與 Token 將會以 `agent` 使用者身分安全寫入。)*

### 6. 刪除 Bot
停止 ECS 服務並清理相關資源：
```bash
ops/aws-destroy.sh <bot名稱> [選項]
```
選項：
- `--purge-state`：同時刪除 S3 中的狀態備份（不可逆）
- `--purge-secret`：同時刪除 AWS Secrets Manager 中的密鑰（不可逆）

例如：
```bash
ops/aws-destroy.sh ghost                        # 僅停止 ECS 服務
ops/aws-destroy.sh ghost --purge-state          # 停止服務並刪除 S3 狀態
ops/aws-destroy.sh ghost --purge-state --purge-secret  # 完整清理
```

### 7. 手動備份與復原 S3 狀態 (非部署流程時使用)
- **同步本地 overlay layers**：執行 `./ops/upload-layers.sh <bot名稱>`，只會同步 Layer 2-5，不會覆蓋 runtime snapshot。
- **復原 runtime 狀態至新目錄**：執行 `./ops/restore-layer1.sh <bot名稱>` 從 S3 下載 runtime snapshot，這會放到 `restored/<bot名稱>` 目錄以防覆蓋。

### 8. 執行測試
驗證部署腳本的 yq 解析與模板渲染是否正確：
```bash
ops/test-deploy.sh
```

---

## 🚀 新增一個 Bot 的步驟

1. **設定 AWS Secrets Manager**：
   在 AWS 建立對應的密鑰（例如 `openab/oab-codex`），至少寫入 `DISCORD_BOT_TOKEN`；若 agent 需要使用 `gh`，同一個 Secret 內再加入 `GH_TOKEN`。可參考 [AWS Secrets Manager 密鑰管理指南](./docs/aws_secrets_manager.md)。
   
2. **在 `bots.yaml` 新增設定**：
   在 [bots.yaml](./ops/bots.yaml) 中加入新 Bot 的實體參數。必須包含以下欄位：
   ```yaml
   <bot_name>:
     backend_agent: <agent_type>        # 必填: agy, codex 等
     image: <container_image>           # 必填: 完整的 image URL
     agent_command: <command>           # 必填: 啟動指令
     secret_path: <sm_path>            # 必填: Secrets Manager 路徑
     cpu: '<cpu_units>'                # 必填: 如 '256', '512', '1024'
     memory: '<memory_mb>'             # 必填: 如 '512', '1024', '2048'
     capacity: <FARGATE_SPOT|FARGATE>  # 必填: 容器容量提供者類型
     state_bucket: ''                   # 選填: 預設使用全域 state_bucket
     pre_boot_url: '<url>'             # 必填: pre-boot 鉤子腳本 URL
     pre_boot_sha256: '<hash>'         # 必填: 腳本的 SHA-256 雜湊值
     pre_shutdown_url: '<url>'         # 必填: pre-shutdown 鉤子腳本 URL
     pre_shutdown_sha256: '<hash>'     # 必填: 腳本的 SHA-256 雜湊值
   ```

3. **驗證設定**：
   ```bash
   ops/validate.sh
   ```

4. **執行部署**：
   ```bash
   ops/deploy.sh <bot_name>
   ```

---

## 🔧 設定檔格式參考

### aws-env.yaml (由 aws-init.sh 自動產生)
```yaml
cluster: openab-cluster
execution_role_arn: arn:aws:iam::<ACCOUNT_ID>:role/openab-task-execution-role
task_role_arn: arn:aws:iam::<ACCOUNT_ID>:role/openab-task-role
state_bucket: openab-state-bucket-<ACCOUNT_ID>
region: us-east-1

subnets: |
  - subnet-xxx
  - subnet-xxx

security_groups: |
  - sg-xxx
```

### Fargate CPU/Memory 合法組合
| CPU (units) | Memory (MB) |
|-------------|-------------|
| 256 | 512, 1024, 2048 |
| 512 | 1024, 2048, 3072 |
| 1024 | 2048, 3072, 4096 |
| 2048 | 4096, 5120, 6144, 8192 |
| 4096 | 8192, 10240, 12288, 16384 |
| 8192 | 16384, 20480, 24576 |
| 16384 | 32768, 49152, 65536 |

完整參考：[AWS Fargate VPU and memory](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AWS_Fargate_VPU_memory.html)
