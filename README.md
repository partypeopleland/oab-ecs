# OpenAB ECS Deployments

這個 repo 用來部署與維運 OpenAB bots 到 AWS ECS Fargate。它把知識拆成 4 個主要區塊：

- `ops/aws-env.yaml`
AWS 環境層設定，由 `ops/aws-init.sh` 產生。

- `ops/bots.yaml`
bot 實例層設定，控制 deploy 內容。

- `state/layers/`
Layer 2-5 靜態內容，例如工具說明、backend 設定、bot 人設與容器內 AGENTS 規則。

- `hooks/*.sh`
容器啟動與關閉 hook 原始碼。

## 先讀哪幾份文件

- [docs/deployment.md](./docs/deployment.md)
主流程入口。部署、更新、sync、偵錯、退役都從這裡開始。

- [docs/bot_configuration_schema.md](./docs/bot_configuration_schema.md)
要改 `ops/bots.yaml` 時看這份。

- [docs/state_layers.md](./docs/state_layers.md)
要理解 Layer 1-5、S3 路徑與 `state/layers/` 時看這份。

- [docs/hook_runtime_lifecycle.md](./docs/hook_runtime_lifecycle.md)
只在修改 hook 或追查 runtime 行為時看。

## 快速開始

初始化 AWS 環境：

```bash
ops/aws-init.sh
```

驗證設定並部署 bot：

```bash
ops/validate.sh
ops/deploy.sh <bot>
```

查看狀態與最近日誌：

```bash
ops/status.sh <bot>
```

## 目錄

- `ops/`
部署腳本、模板與設定檔。

- `hooks/`
`pre-boot.sh` / `pre-shutdown.sh` 的唯一原始碼。

- `state/layers/`
Layer 2-5 靜態內容來源。

- `restored/`
`ops/restore-layer1.sh` 下載 Layer 1 runtime snapshot 的本地落點。

## 常見變更對照

| 你要改什麼 | 主要位置 | 下一步 |
|---|---|---|
| image、cpu、memory、secret_path、capacity | `ops/bots.yaml` | `ops/validate.sh` -> `ops/deploy.sh <bot>` |
| 共用工具說明或 helper script | `state/layers/2-common/` | `ops/upload-layers.sh <bot>` |
| backend 共用設定 | `state/layers/3-backend/<backend>/` | `ops/upload-layers.sh <bot>` |
| bot 專屬人設或靜態內容 | `state/layers/4-bot/<bot>/` | `ops/upload-layers.sh <bot>` |
| 全域容器內 AGENTS 規則 | `state/layers/5-agents/AGENTS.md` | `ops/upload-layers.sh <bot>` |
| hook 行為 | `hooks/*.sh` | `ops/sync-hook-gists.sh` -> `ops/deploy.sh <bot>` |

## 重要提醒

1. `ops/aws-env.yaml` 是產物，不是長期手改來源。
2. Layer 1 runtime 不在 repo 內編輯；`state/layers/` 只放 Layer 2-5。
3. 改 `hooks/*.sh` 後不要直接 deploy，先同步 gist。
4. 若要在容器內做登入，先切到 `agent` 使用者，避免憑證檔權限錯誤。
