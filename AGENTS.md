# oab-ecs AI 導覽

這個 repo 用來管理 OpenAB bot 在 AWS ECS Fargate 上的部署、狀態分層與 runtime 還原。

先記住這 4 件事：

1. `ops/aws-env.yaml` 是 AWS 環境層設定，由 `ops/aws-init.sh` 產生。
2. `ops/bots.yaml` 是 bot 實例層設定，控制 deploy 結果。
3. `state/layers/` 是 Layer 2-5 靜態內容；Layer 1 runtime 不在 repo 內。
4. `hooks/*.sh` 是 hook 原始碼，但 deploy 實際用的是 `bots.yaml` 裡的 gist URL 與 SHA。

## 先讀哪裡

1. `docs/deployment.md`
主流程入口。部署、更新、sync、偵錯、退役都先看這份。

2. `docs/bot_configuration_schema.md`
需要修改 `ops/bots.yaml` 時看這份。

3. `docs/state_layers.md`
需要理解 `state/layers/`、S3 路徑或 runtime snapshot 時看這份。

4. `docs/hook_runtime_lifecycle.md`
只在修改 hook 或追查啟動/關閉行為時閱讀。

## Repo 地圖

- `ops/`
操作腳本與部署資料。

- `ops/aws-init.sh`
初始化 AWS 資源並產生 `ops/aws-env.yaml`。

- `ops/deploy.sh`
讀取 `bots.yaml` + `aws-env.yaml`，渲染模板並 deploy。

- `ops/upload-layers.sh`
把 `state/layers/2-5` 同步到 S3。

- `ops/sync-hook-gists.sh`
把 `hooks/*.sh` 同步到 gist，並更新 `bots.yaml` 內的 SHA。

- `ops/status.sh`
看 ECS service 狀態與最近日誌。

- `ops/check-layers.sh`
從日誌確認 pre-boot 是否成功還原 Layer 1-5。

- `ops/restore-layer1.sh`
把 S3 的 Layer 1 runtime snapshot 還原到本地 `restored/`。

- `state/layers/2-common/`
所有 bot 共用的工具說明與 helper script。

- `state/layers/3-backend/<backend>/`
backend 共用設定。

- `state/layers/4-bot/<bot>/`
bot 專屬靜態內容與人設。

- `state/layers/5-agents/AGENTS.md`
容器內最終會覆蓋到 `/home/agent/AGENTS.md` 的全域規則。

## 常見任務對照

| 任務 | 改哪裡 | 下一步 |
|---|---|---|
| 調整 image、cpu、memory、capacity、secret_path | `ops/bots.yaml` | `ops/validate.sh` -> `ops/deploy.sh <bot>` |
| 改共享工具說明或 helper | `state/layers/2-common/` | `ops/upload-layers.sh <bot>` |
| 改 backend 共用設定 | `state/layers/3-backend/<backend>/` | `ops/upload-layers.sh <bot>` |
| 改 bot 人設或專屬靜態內容 | `state/layers/4-bot/<bot>/` | `ops/upload-layers.sh <bot>` |
| 改所有 bot 共用的容器內 AGENTS 規則 | `state/layers/5-agents/AGENTS.md` | `ops/upload-layers.sh <bot>` |
| 改 hook 啟動或關閉邏輯 | `hooks/*.sh` | `ops/sync-hook-gists.sh` -> `ops/deploy.sh <bot>` |
| 初始化或修正 AWS 環境 | `ops/aws-init.yaml` / `ops/aws-init.sh` | 重新產生 `ops/aws-env.yaml` |

## 不變條件

1. 不要把 AWS 環境級參數寫進 `ops/bots.yaml`。
2. 不要把 runtime 生成檔案直接放進 `state/layers/`。
3. 不要改了 `hooks/*.sh` 就直接 deploy，先 sync gist。
4. `ops/upload-layers.sh` 只處理 Layer 2-5，不會處理 Layer 1。
5. bot 名稱會連動 service 名稱、log group、Layer 4 路徑、runtime key、secret 命名慣例。

## 工作方式

- 不預設解決方案，所有任務進行都依使用者指示，除非使用者同意，否則不會進行任何操作。
- 先分析任務，列出步驟，確認是否有足夠的資訊來完成任務。
- 執行所有任務先告知預計怎麼處理，遇到問題回報狀況。
