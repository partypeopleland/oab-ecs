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
  * [aws_infrastructure.md](./docs/aws_infrastructure.md) - AWS 基礎架構初始化指南
  * [aws_secrets_manager.md](./docs/aws_secrets_manager.md) - AWS Secrets Manager 密鑰管理指南
  * [bot_configuration_schema.md](./docs/bot_configuration_schema.md) - `bots.yaml` 欄位契約與部署模板映射
  * [deployment.md](./docs/deployment.md) - 機器人部署指南
  * [hooks_gist_sync.md](./docs/hooks_gist_sync.md) - hook 腳本與 gist 同步規範
  * [hook_runtime_lifecycle.md](./docs/hook_runtime_lifecycle.md) - hook 執行生命週期、快取與 runtime state 還原流程
  * [observability.md](./docs/observability.md) - 監控、日誌與容器偵錯指南
  * [ops_scripts_reference.md](./docs/ops_scripts_reference.md) - `ops/` 常用維運腳本參考
  * [state_layers.md](./docs/state_layers.md) - 狀態分層、本地目錄與 S3 路徑模型
* [hooks/](./hooks) - 容器啟動與關閉的鉤子腳本目錄，包含 [pre-boot.sh](./hooks/pre-boot.sh) 與 [pre-shutdown.sh](./hooks/pre-shutdown.sh)
* [state/](./state) - 本地靜態 overlay layers 目錄，對應 Layer 2-5（Layer 1 runtime 不落在 repo）
* [ops/](./ops) - 維運相關腳本與設定目錄：
  * [bots.yaml](./ops/bots.yaml) - 所有 Bot 實例的設定對照表
  * [openab-ecs.yaml.template](./ops/openab-ecs.yaml.template) - 通用的 ECS Service 部署模板
  * [aws-init.yaml](./ops/aws-init.yaml) - AWS 資源建置名稱的預設設定檔
  * [aws-init.sh](./ops/aws-init.sh) - 環境初始化與自動探測指令腳本
  * [deploy.sh](./ops/deploy.sh) - 自動化部署/渲染指令腳本 (Bash, 使用 yq)
  * [validate.sh](./ops/validate.sh) - 驗證 bots.yaml 設定是否合法 (Bash, 使用 yq)
  * [aws-destroy.sh](./ops/aws-destroy.sh) - 停止並清理 Bot 的 ECS 服務及相關資源 (Bash)
  * [upload-layers.sh](./ops/upload-layers.sh) - 手動同步本地 overlay layers 至 S3 (Bash)
  * [restore-layer1.sh](./ops/restore-layer1.sh) - 從 S3 下載與還原 Layer 1 狀態至本地新路徑 (Bash)
  * [check-layers.sh](./ops/check-layers.sh) - 檢查運行中容器的 Layer 2-5 同步狀態 (Bash)
  * [status.sh](./ops/status.sh) - 查詢特定 Bot 的 ECS 服務狀態、任務詳情與最新日誌 (Bash)
  * [sync-hook-gists.sh](./ops/sync-hook-gists.sh) - 將 `hooks/` 目錄中的 hook 腳本同步到 GitHub gist，並刷新 `bots.yaml` 的 SHA-256
  * [tests/](./ops/tests) - 各腳本對應的驗證資料與測試腳本
  * `aws-env.yaml` - (Git 忽略) 自動生成的本地 AWS 環境與網路設定檔案
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

`bots.yaml` 的完整欄位契約、預設值與模板映射，請看 [docs/bot_configuration_schema.md](./docs/bot_configuration_schema.md)。

### 2. 通用模板 (`openab-ecs.yaml.template`)
定義標準的 `ecsctl` Fargate Service 設定，部署時由 `ops/deploy.sh` 將 `bots.yaml` 與 `aws-env.yaml` 渲染成實際 YAML。模板欄位如何映射到容器環境與 `config.toml`，請看 [docs/bot_configuration_schema.md](./docs/bot_configuration_schema.md)。

### 3. 狀態與人設管理機制 (S3 State & Layering)
Bot 狀態分成 Layer 1 runtime snapshot 與 Layer 2-5 靜態 overlay。S3 路徑模型、還原順序與 `upload-layers.sh` 的責任邊界，請看 [docs/state_layers.md](./docs/state_layers.md)。

#### 📌 如何設定「專屬人設」與「工具說明」？
* **全域共用維運規則**：請編輯 `state/layers/5-agents/AGENTS.md`。
* **個別 Bot 專屬人設**：請建立於 `state/layers/4-bot/<bot>/` 下（例如 `state/layers/4-bot/ghost/steering/Identity.md`）。
* **共用工具說明**：請編輯 `state/layers/2-common/TOOLS.md`。

### 4. 工具快取與下載機制
容器啟動時會安裝固定版本 AWS CLI、優先自 S3 載入 `uv` 快取，並透過 `pre_boot` / `pre_shutdown` 還原與備份 runtime state。完整 lifecycle 請看 [docs/hook_runtime_lifecycle.md](./docs/hook_runtime_lifecycle.md)。

---

## 📋 部署 SOP 與指令範例

> [!NOTE]
> **腳本說明來源**
> `ops/` 目錄下各腳本的參數、範例與注意事項，請以該腳本本身的 `--help` 為準，例如 `ops/deploy.sh --help`。
> [docs/ops_scripts_reference.md](./docs/ops_scripts_reference.md) 僅作為一覽表與導覽。

### 前置作業：初始化環境
先確保本機已完成 `aws configure`，如需自訂資源名稱或明確指定 VPC / subnet，先編輯 [aws-init.yaml](./ops/aws-init.yaml)，再執行：
```bash
ops/aws-init.sh
```
初始化細節請看 [docs/aws_infrastructure.md](./docs/aws_infrastructure.md)。

### 1. 驗證設定
在部署前，先驗證 `bots.yaml`：
```bash
ops/validate.sh
```

### 2. 部署 Bot
使用自動化部署腳本：
```bash
ops/deploy.sh <bot名稱>
```

### 3. 僅渲染 YAML（不部署）
如果只想查看替換後的部署 YAML，可加上 `render`：
```bash
ops/deploy.sh ghost render
```
完整部署流程請看 [docs/deployment.md](./docs/deployment.md)。

### 4. 查詢服務狀態
快速查看服務與最近日誌：
```bash
ops/status.sh ghost
```
更完整的觀測與偵錯方式請看 [docs/observability.md](./docs/observability.md) 與 [docs/ops_scripts_reference.md](./docs/ops_scripts_reference.md)。

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
選項與副作用請看 [docs/ops_scripts_reference.md](./docs/ops_scripts_reference.md)。

### 7. 手動備份與復原 S3 狀態 (非部署流程時使用)
- **同步本地 overlay layers**：執行 `./ops/upload-layers.sh <bot名稱>`，只會同步 Layer 2-5，不會覆蓋 runtime snapshot。
- **復原 runtime 狀態至新目錄**：執行 `./ops/restore-layer1.sh <bot名稱>` 從 S3 下載 runtime snapshot，這會放到 `restored/<bot名稱>` 目錄以防覆蓋。

這兩支腳本的責任邊界請看 [docs/state_layers.md](./docs/state_layers.md) 與 [docs/ops_scripts_reference.md](./docs/ops_scripts_reference.md)。

### 8. 執行測試
測試腳本集中放在 `ops/tests/`，供 repo 內部驗證使用。

---

## 🚀 新增一個 Bot 的步驟

1. **設定 AWS Secrets Manager**：
   在 AWS 建立對應的密鑰（例如 `openab/oab-codex`），至少寫入 `DISCORD_BOT_TOKEN`；若 agent 需要使用 `gh`，同一個 Secret 內再加入 `GH_TOKEN`。可參考 [AWS Secrets Manager 密鑰管理指南](./docs/aws_secrets_manager.md)。
   
2. **在 `bots.yaml` 新增設定**：
   在 [bots.yaml](./ops/bots.yaml) 中加入新 Bot 的實體參數。完整 schema 請看 [docs/bot_configuration_schema.md](./docs/bot_configuration_schema.md)。

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
