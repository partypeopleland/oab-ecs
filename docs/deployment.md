# 部署與維運流程

這份文件是本 repo 的主操作入口。AI 若要部署、更新、偵錯或退役 bot，先讀這份，再視需要展開到：

- [bot_configuration_schema.md](./bot_configuration_schema.md)：`ops/bots.yaml` 欄位契約
- [state_layers.md](./state_layers.md)：Layer 1-5 模型與 S3 路徑
- [hook_runtime_lifecycle.md](./hook_runtime_lifecycle.md)：`pre-boot.sh` / `pre-shutdown.sh` 的實際行為

## 先理解四個來源

1. `ops/aws-env.yaml`
由 `ops/aws-init.sh` 產生。放 AWS 環境級資訊，例如 cluster、role ARN、subnets、security groups、預設 `state_bucket`。

2. `ops/bots.yaml`
放 bot 實例專屬設定，例如 image、capacity、secret_path、hook URL。

3. `state/layers/`
放 Layer 2-5 靜態內容。修改後要用 `ops/upload-layers.sh <bot>` 上傳到 S3。

4. `hooks/`
repo 內的 hook 原始碼。deploy 實際使用的是 `bots.yaml` 裡的 gist URL 與 SHA，不是本地檔案本身。

## 核心資料流

```text
ops/aws-init.sh
    |
    v
ops/aws-env.yaml

ops/bots.yaml -----------+
                         |
hooks/*.sh --sync--> gist URL / SHA in bots.yaml
                         |
state/layers/ --upload-> S3 layers bucket
                         |
                         v
                 ops/deploy.sh
                     |
                     v
       openab-ecs.yaml.template -> .deploy-<bot>.yaml
                     |
                     v
                 ecsctl apply
                     |
                     v
             ECS Fargate container
```

重點：

- `aws-env.yaml` 提供環境層資料
- `bots.yaml` 提供 bot 實例層資料
- hook 與 layers 在 deploy 前要先同步到它們真正的使用來源

## 前置條件

本 repo 常用工具：

- `aws`
- `ecsctl`
- `yq`
- `jq`
- `gh`
- `curl`

執行前通常需要：

- `aws configure` 已完成
- GitHub 認證已完成，擇一即可：
  - `gh auth login`
  - 或先設定 `GH_TOKEN`

`GH_TOKEN` 是 `gh` 官方支援的環境變數。若已設定有效 token，`gh` 可直接用它發 API 請求，不一定需要先執行 `gh auth login`。

若腳本用法有疑問，以各 script 的 `--help` 為準。

## 常見工作流程

### 初始化 AWS 環境

第一次在某個 AWS 帳號或區域使用時：

```bash
ops/aws-init.sh
```

這支腳本會確認或建立：

- ECS cluster
- task execution role
- task role
- security group
- subnets
- state bucket

並產生 `ops/aws-env.yaml`。

如果不是 default VPC，或你要固定 VPC / subnet，先修改 `ops/aws-init.yaml`。

### 部署既有 bot

```bash
ops/validate.sh
ops/deploy.sh <bot>
```

```text
edit bots.yaml
    |
    v
ops/validate.sh
    |
    v
ops/deploy.sh <bot>
    |
    v
CloudWatch / ecsctl / status.sh 驗證結果
```

如果只想看渲染結果，不實際部署：

```bash
ops/deploy.sh <bot> render
```

`deploy.sh` 會讀取 `aws-env.yaml` 與 `bots.yaml`，渲染 `ops/openab-ecs.yaml.template`，再執行 `ecsctl apply`。

### 修改 bot 設定

修改 [ops/bots.yaml](../ops/bots.yaml) 後：

```bash
ops/validate.sh
ops/deploy.sh <bot>
```

欄位語意、預設值與映射規則請看 [bot_configuration_schema.md](./bot_configuration_schema.md)。

### 修改共享工具、backend 設定、bot 人設或全域 AGENTS

修改 `state/layers/` 後：

```bash
ops/upload-layers.sh <bot>
ops/deploy.sh <bot>
```

`upload-layers.sh` 只會同步 Layer 2-5，不會覆蓋 Layer 1 runtime snapshot。

### 修改 hook

修改 [hooks/pre-boot.sh](../hooks/pre-boot.sh) 或 [hooks/pre-shutdown.sh](../hooks/pre-shutdown.sh) 後，必須先同步 gist：

```bash
ops/sync-hook-gists.sh
ops/deploy.sh <bot>
```

```text
hooks/pre-boot.sh or pre-shutdown.sh
                |
                v
       ops/sync-hook-gists.sh
                |
                v
  update gist content + bots.yaml sha/url
                |
                v
         ops/deploy.sh <bot>
                |
                v
   container downloads remote hook by URL
```

若你不想使用互動式登入，可先設定：

```bash
export GH_TOKEN=<your_token>
```

之後再執行 `ops/sync-hook-gists.sh`。只要這個 token 對目標 gist 有寫入權限，就不需要先跑 `gh auth login`。

原因：

- repo 內 `hooks/` 是唯一原始碼
- deploy 實際用的是 `bots.yaml` 的 `pre_*_url` 與 `pre_*_sha256`
- 若不先 sync gist，常見結果是 `hook sha256 mismatch`

### 建立或更新 secret

最常見做法是使用：

```bash
ops/create-secret.sh <bot> <DISCORD_BOT_TOKEN>
ops/create-secret.sh openab/oab-<bot> GH_TOKEN <token>
```

重要契約：

- `DISCORD_BOT_TOKEN` 是必要的
- `GH_TOKEN` 是可選的
- `secret_path` 由 `bots.yaml` 定義
- task role 必須有 `secretsmanager:GetSecretValue`

deploy 產出的 `config.toml` 會用：

- `aws-sm://<secret_path>#DISCORD_BOT_TOKEN`
- `/home/agent/.openab/get-optional-gh-token.sh <secret_path>`

若使用可選的 `GH_TOKEN` helper，記得把 `state/layers/2-common/.openab/` 透過 `ops/upload-layers.sh <bot>` 同步上去。

### 部署後驗證與偵錯

先看整體狀態與最近日誌：

```bash
ops/status.sh <bot>
```

要檢查 pre-boot 是否成功還原 Layer 1-5：

```bash
ops/check-layers.sh <bot>
```

要進容器內檢查：

```bash
ecsctl exec openab-<bot> bash
```

進去後優先檢查：

- `/home/agent/config.toml`
- `env`
- `/home/agent/AGENTS.md`
- `/home/agent/.openab/`

若需要互動式登入，先切到 `agent` 使用者再操作，避免憑證檔變成 `root` 擁有：

```bash
su - agent
agentauth
```

### 還原 runtime snapshot 到本地

```bash
ops/restore-layer1.sh <bot>
```

這會把 Layer 1 還原到 `restored/<bot>/`，不會覆蓋 repo 內檔案。

### 退役 bot

```bash
ops/aws-destroy.sh <bot> [--purge-state] [--purge-secret]
```

- `--purge-state`：刪除 S3 中 runtime 與 Layer 4 bot 靜態內容
- `--purge-secret`：刪除 Secrets Manager secret

## 操作判斷表

| 你要改什麼 | 主要位置 | 下一步 |
|---|---|---|
| ECS image、cpu、memory、secret_path、hook URL | `ops/bots.yaml` | `ops/validate.sh` -> `ops/deploy.sh <bot>` |
| 共用工具說明或 helper script | `state/layers/2-common/` | `ops/upload-layers.sh <bot>` |
| backend 共用設定 | `state/layers/3-backend/<backend>/` | `ops/upload-layers.sh <bot>` |
| bot 專屬人設或靜態檔 | `state/layers/4-bot/<bot>/` | `ops/upload-layers.sh <bot>` |
| 所有 bot 共用的 AGENTS 規則 | `state/layers/5-agents/AGENTS.md` | `ops/upload-layers.sh <bot>` |
| 啟動或關閉 hook 行為 | `hooks/*.sh` | `ops/sync-hook-gists.sh` -> `ops/deploy.sh <bot>` |
| AWS 基礎環境 | `ops/aws-init.yaml` / `ops/aws-init.sh` | 重新產生 `ops/aws-env.yaml` |

## 幾個容易犯錯的點

1. 不要手改 `ops/aws-env.yaml` 當成長期來源。它是 `ops/aws-init.sh` 產物。
2. 不要把 runtime 檔案放進 `state/layers/`。登入狀態、sqlite、cache 屬於 Layer 1。
3. 不要改了 `hooks/*.sh` 就直接 deploy。先 `ops/sync-hook-gists.sh`。
4. 不要在 `root` 身分下做需要持久化的 agent 登入。
5. `upload-layers.sh` 會對 Layer 2-4 使用 `aws s3 sync --delete`，要注意刪除效果。
