# 維運腳本參考

本文件作為 `ops/` 腳本的一覽表。各腳本的完整參數、範例與注意事項，請直接執行對應的 `--help`。

## 一覽表

| Script | 用途 | 詳細用法 |
|---|---|---|
| `ops/aws-init.sh` | 探測或建立 AWS 基礎資源，產生 `ops/aws-env.yaml` | `ops/aws-init.sh --help` |
| `ops/validate.sh` | 驗證 `ops/bots.yaml` 設定是否合法 | `ops/validate.sh --help` |
| `ops/deploy.sh` | 渲染 ECS 模板並部署 bot | `ops/deploy.sh --help` |
| `ops/create-secret.sh` | 建立 secret 或更新既有 secret 的單一欄位 | `ops/create-secret.sh --help` |
| `ops/status.sh` | 查看 ECS service 狀態、task 與最近日誌 | `ops/status.sh --help` |
| `ops/check-layers.sh` | 檢查 pre-boot 是否成功載入 Layer 1-5 | `ops/check-layers.sh --help` |
| `ops/upload-layers.sh` | 將本地 Layer 2-5 同步到 S3 | `ops/upload-layers.sh --help` |
| `ops/restore-layer1.sh` | 從 S3 還原 Layer 1 runtime snapshot 到本地 | `ops/restore-layer1.sh --help` |
| `ops/aws-destroy.sh` | 退役 bot，並可選擇清理 state 與 secret | `ops/aws-destroy.sh --help` |

## 補充

* AWS 環境初始化與 `aws-env.yaml` 內容，請看 `docs/aws_infrastructure.md`
* 部署流程與 hook / state / secret 的整體關係，請看 `docs/deployment.md`
* 若腳本行為與文件不同，以腳本本身的 `--help` 與實際程式碼為準
* `ops/tests/` 內的測試腳本屬於 repo 內部驗證，不列入對外維運介面

## 建議使用順序

常見的維運節奏如下：

1. 修改 `ops/bots.yaml` 或 `state/layers/`
2. 執行 `ops/validate.sh`
3. 若有改 hook，執行 `ops/sync-hook-gists.sh`
4. 若有改 Layer 2-5，執行 `ops/upload-layers.sh <bot>`
5. 執行 `ops/deploy.sh <bot>`
6. 用 `ops/status.sh <bot>` 驗證服務
7. 如需追查 layer 還原，再執行 `ops/check-layers.sh <bot>`
8. 如需檢查 runtime 狀態，執行 `ops/restore-layer1.sh <bot>`
