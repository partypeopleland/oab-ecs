# Bot 設定模型與模板映射

本文件描述 `ops/bots.yaml` 的資料模型、欄位語意，以及這些欄位如何被 `ops/deploy.sh` 映射進 `ops/openab-ecs.yaml.template`。

目標是讓人類與 AI 在修改 Bot 設定時，可以先理解「哪些值只是 metadata、哪些值會直接影響部署結果」。

## 單一責任

`ops/bots.yaml` 只負責 **Bot 實例專屬設定**。

它不應承載：

* AWS 帳號、VPC、subnet、security group 等環境級資訊
* IAM Role ARN
* ECS Cluster 名稱

這些全域環境參數應放在 `ops/aws-env.yaml`，並由 `ops/aws-init.sh` 產生。

## Schema

每個頂層 key 都是一個 bot 名稱，例如：

```yaml
ghost:
  backend_agent: agy
  image: ghcr.io/openabdev/openab-antigravity:0.8.5-beta.9
  agent_command: agy-acp
  agent_args: '[]'
  secret_path: openab/oab-ghost
  cpu: '256'
  memory: '512'
  capacity: FARGATE_SPOT
  state_bucket: ''
  pre_boot_url: 'https://gist.githubusercontent.com/.../raw/pre-boot.sh'
  pre_boot_sha256: '...'
  pre_shutdown_url: 'https://gist.githubusercontent.com/.../raw/pre-shutdown.sh'
  pre_shutdown_sha256: '...'
```

## 欄位說明

### `backend_agent`

* 用途：標示 bot 所屬 backend 類型，例如 `agy`、`kiro`。
* 影響：
  * 會寫入容器環境變數 `OPENAB_BACKEND_AGENT`
  * `pre-boot.sh` 會依此載入 `layers/3-backend/<backend>/`
  * `ops/upload-layers.sh` 會同步對應的 Layer 3 目錄

### `image`

* 用途：ECS Task 使用的容器映像。
* 影響：直接映射到 `spec.image`
* 要求：需可在 ECS Fargate `X86_64` 上運行

### `agent_command`

* 用途：OpenAB 在容器內啟動 agent 的主指令。
* 影響：
  * 會寫入環境變數 `OPENAB_AGENT_COMMAND`
  * 會寫入產出的 `/home/agent/config.toml`：
    ```toml
    [agent]
    command = "<agent_command>"
    ```

### `agent_args`

* 用途：agent 啟動參數，格式必須是可直接嵌入 TOML 的陣列字串。
* 範例：
  * `[]`
  * `["acp", "--trust-all-tools"]`
* 預設行為：若未設定、為空字串或 `null`，`deploy.sh` 會自動補成 `[]`
* 影響：直接寫入 `/home/agent/config.toml` 的 `args`

### `secret_path`

* 用途：Secrets Manager secret id，例如 `openab/oab-ghost`
* 影響：
  * `DISCORD_BOT_TOKEN` 由 `aws-sm://<secret_path>#DISCORD_BOT_TOKEN` 載入
  * `GH_TOKEN` 由 `/home/agent/.openab/get-optional-gh-token.sh <secret_path>` 嘗試讀取

### `cpu` / `memory`

* 用途：Fargate task 資源配置
* 型別：必須是字串，例如 `'256'`、`'512'`
* 影響：直接映射到 `spec.cpu` 與 `spec.memory`
* 驗證：`ops/validate.sh` 會檢查是否為合法的 Fargate 組合

### `capacity`

* 允許值：
  * `FARGATE_SPOT`
  * `FARGATE`
* 影響：直接映射到 `spec.capacity`

### `state_bucket`

* 用途：可選的 bot 專屬 S3 bucket 覆寫
* 預設行為：若為空字串或 `null`，`deploy.sh` 會回退使用 `ops/aws-env.yaml` 的全域 `state_bucket`
* 影響：寫入環境變數 `STATE_BUCKET`，供 hook 與 runtime state 使用

### `pre_boot_url` / `pre_shutdown_url`

* 用途：指定 hook 腳本的遠端來源
* 實際使用者：ECS deploy 後由 OpenAB 下載並執行，不是直接讀 repo 內的 `hooks/*.sh`
* 特別行為：`deploy.sh` 若偵測到 `gist.githubusercontent.com`，會自動附加 `?t=<timestamp>` 以降低 CDN 快取造成的舊內容問題

### `pre_boot_sha256` / `pre_shutdown_sha256`

* 用途：驗證 hook 腳本內容
* 維護方式：修改 `hooks/*.sh` 後，應執行 `ops/sync-hook-gists.sh` 重新同步 gist 並刷新 hash

## 部署時的映射結果

`ops/deploy.sh` 會把 `bots.yaml` 與 `aws-env.yaml` 合併後渲染到 `.deploy-<bot>.yaml`。主要映射如下：

* `metadata.name` = `openab-<bot>`
* `spec.containerName` = `openab-<bot>`
* `spec.logGroup` = `/ecs/openab-<bot>`
* `env.OPENAB_AGENT_NAME` = `<bot>`
* `env.OPENAB_BACKEND_AGENT` = `backend_agent`
* `env.OPENAB_AGENT_COMMAND` = `agent_command`
* `env.STATE_BUCKET` = bot 專屬或全域 bucket
* `config.toml [agent].command` = `agent_command`
* `config.toml [agent].args` = `agent_args`
* `config.toml [hooks.pre_boot]` = `pre_boot_url` / `pre_boot_sha256`
* `config.toml [hooks.pre_shutdown]` = `pre_shutdown_url` / `pre_shutdown_sha256`

## 命名與相依關係

Bot 名稱會同時影響多個地方，因此改名不是單純改一個 key：

* ECS Service / Container / Log Group 名稱都會跟著變成 `openab-<bot>`
* Layer 4 S3 路徑會變成 `layers/4-bot/<bot>/`
* Layer 1 runtime key 會變成 `runtime/<bot>/home.tar.gz`
* 預設 secret 命名慣例通常是 `openab/oab-<bot>`

若要改 bot 名稱，通常必須同步檢查：

* `ops/bots.yaml`
* `state/layers/4-bot/<bot>/`
* S3 state 與 runtime key
* Secrets Manager secret path
* 既有 ECS service / CloudWatch log group

## 建議修改流程

1. 先編輯 `ops/bots.yaml`
2. 執行 `ops/validate.sh`
3. 如有修改 hook，先執行 `ops/sync-hook-gists.sh`
4. 如有修改 Layer 2-5 靜態內容，先執行 `ops/upload-layers.sh <bot>`
5. 最後執行 `ops/deploy.sh <bot>` 或 `ops/deploy.sh <bot> render`
