# `ops/bots.yaml` 契約

這份文件只描述 `ops/bots.yaml`。它回答三件事：

1. 哪些欄位是 bot 專屬設定
2. 這些欄位會影響哪個部署結果
3. 改完後通常還要同步檢查哪些地方

## 邊界

`ops/bots.yaml` 只放 bot 實例專屬設定，不放：

- AWS 帳號
- VPC / subnet / security group
- cluster 名稱
- IAM role ARN

這些屬於 `ops/aws-env.yaml`，由 `ops/aws-init.sh` 產生。

## 最小範例

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
  pre_boot_url: https://gist.githubusercontent.com/.../raw/pre-boot.sh
  pre_boot_sha256: ...
  pre_shutdown_url: https://gist.githubusercontent.com/.../raw/pre-shutdown.sh
  pre_shutdown_sha256: ...
```

## 欄位表

| 欄位 | 用途 | 影響 |
|---|---|---|
| `backend_agent` | backend 類型，例如 `agy`、`kiro` | 寫入 `OPENAB_BACKEND_AGENT`；決定 Layer 3 路徑 `layers/3-backend/<backend>/` |
| `image` | ECS task 容器映像 | 映射到 `spec.image` |
| `agent_command` | 容器內啟動 agent 的主指令 | 寫入 `OPENAB_AGENT_COMMAND` 與 `config.toml [agent].command` |
| `agent_args` | agent 啟動參數，必須是可直接嵌入 TOML 的陣列字串 | 寫入 `config.toml [agent].args`；空值會被補成 `[]` |
| `secret_path` | Secrets Manager secret id | `DISCORD_BOT_TOKEN` 與可選 `GH_TOKEN` 的來源 |
| `cpu` / `memory` | Fargate task 資源配置 | 映射到 `spec.cpu` / `spec.memory`；`ops/validate.sh` 會檢查組合是否合法 |
| `capacity` | `FARGATE` 或 `FARGATE_SPOT` | 映射到 `spec.capacity` |
| `state_bucket` | bot 專屬 S3 bucket 覆寫 | 空值時回退到 `ops/aws-env.yaml` 的全域 `state_bucket` |
| `pre_boot_url` / `pre_shutdown_url` | hook 的遠端來源 | deploy 後 OpenAB 下載並執行這些 URL |
| `pre_boot_sha256` / `pre_shutdown_sha256` | hook 內容的校驗值 | 修改 `hooks/*.sh` 後要用 `ops/sync-hook-gists.sh` 更新 |

## 幾個關鍵行為

### `agent_args`

必須是 TOML 陣列字串，例如：

- `[]`
- `["acp", "--trust-all-tools"]`

不是 YAML 陣列，也不是 shell 片段。

### `secret_path`

deploy 產生的 `config.toml` 會用：

- `aws-sm://<secret_path>#DISCORD_BOT_TOKEN`
- `exec:///home/agent/.openab/get-optional-gh-token.sh <secret_path>`

因此：

- `DISCORD_BOT_TOKEN` 是必要欄位
- `GH_TOKEN` 是可選欄位

### hook URL

`pre_boot_url` / `pre_shutdown_url` 指向遠端 gist。deploy 不會直接讀 repo 內的 `hooks/*.sh`。

如果 URL 是 `gist.githubusercontent.com`，`ops/deploy.sh` 會自動附加時間戳 query 參數來降低 CDN 快取影響。

## 主要映射結果

`ops/deploy.sh` 會把 `bots.yaml` 與 `aws-env.yaml` 合併後渲染到 `.deploy-<bot>.yaml`。主要效果如下：

- 服務名稱：`openab-<bot>`
- container 名稱：`openab-<bot>`
- log group：`/ecs/openab-<bot>`
- `OPENAB_AGENT_NAME`：`<bot>`
- `OPENAB_BACKEND_AGENT`：`backend_agent`
- `OPENAB_AGENT_COMMAND`：`agent_command`
- `STATE_BUCKET`：bot 專屬或全域 bucket
- `config.toml [agent].command`：`agent_command`
- `config.toml [agent].args`：`agent_args`
- `config.toml [hooks.pre_boot]`：`pre_boot_url` / `pre_boot_sha256`
- `config.toml [hooks.pre_shutdown]`：`pre_shutdown_url` / `pre_shutdown_sha256`

## 改 bot 名稱時要注意

bot 名稱不是單純改一個 key。它會連動：

- ECS service / container / log group：`openab-<bot>`
- Layer 4 路徑：`state/layers/4-bot/<bot>/`
- runtime key：`runtime/<bot>/home.tar.gz`
- 預設 secret 慣例：`openab/oab-<bot>`

通常至少要同步檢查：

- `ops/bots.yaml`
- `state/layers/4-bot/<bot>/`
- S3 上的 runtime 與 layer 路徑
- secret path
- 現有 ECS service 與 CloudWatch log group

## 最常見的修改後動作

| 變更 | 後續動作 |
|---|---|
| 改 image、cpu、memory、capacity、agent command | `ops/validate.sh` -> `ops/deploy.sh <bot>` |
| 改 hook URL / SHA | 通常代表先處理 hook 原始碼，再 `ops/sync-hook-gists.sh` |
| 改 backend_agent | 檢查 `state/layers/3-backend/<backend>/` 是否存在，再 `ops/upload-layers.sh <bot>` |
| 改 state_bucket | 確認 bucket 內已有需要的 layers / runtime |
