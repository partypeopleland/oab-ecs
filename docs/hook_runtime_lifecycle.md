# Hook 與 Runtime 生命週期

本文件描述 `hooks/pre-boot.sh` 與 `hooks/pre-shutdown.sh` 的實際責任、執行順序，以及它們如何與 `state layers`、S3 與容器內 `/home/agent` 協作。

這份文件補足的是「hook 做了什麼」，不是「hook 如何同步到 gist」。gist 同步規範請看 `docs/hooks_gist_sync.md`。

## 生命週期總覽

容器生命週期可拆成三段：

1. OpenAB 啟動前執行 `pre_boot`
2. OpenAB 主程式在容器中運行
3. OpenAB 結束前執行 `pre_shutdown`

`openab-ecs.yaml.template` 會把兩個 hook 寫入 `/home/agent/config.toml`：

```toml
[hooks.pre_boot]
timeout_seconds = 120
on_failure = "abort"

[hooks.pre_shutdown]
timeout_seconds = 120
on_failure = "abort"
```

這代表：

* `pre_boot` 失敗會中止啟動
* `pre_shutdown` 失敗不會回滾已經結束的容器，但可能導致最新 runtime state 沒有成功備份

## `pre-boot.sh` 的責任

`pre-boot.sh` 的核心目標是把容器的 `/home/agent` 還原成可運作狀態。

### 1. 建立工具目錄與基本環境

* 設定 `HOME=${HOME:-/home/agent}`
* 建立 `$HOME/bin`
* 關閉 AWS pager：`AWS_PAGER=""`

### 2. 安裝固定版本 AWS CLI

目前腳本固定下載：

* AWS CLI `2.35.7`

行為重點：

* 每次啟動都重新下載官方 zip
* 安裝到 `$HOME/bin/aws` 與 `$HOME/aws-cli`
* 不依賴容器映像內預裝版本

這個設計的目的，是避免 `latest` 版本漂移造成冷啟動差異。

### 3. 載入或下載 `uv`

目前腳本固定使用：

* `uv 0.11.21`

流程：

1. 先嘗試從 `s3://$STATE_BUCKET/cache/uv-0.11.21-x86_64-unknown-linux-musl.tar.gz` 取回快取
2. 若快取不存在，就從 GitHub release 下載
3. 下載時會額外抓 `.sha256` 並驗證
4. 成功後寫入 `$HOME/bin/uv`
5. 若是首次下載且 bucket 可寫，會回寫到 S3 快取

## State 還原順序

`pre-boot.sh` 真正重要的部分，是依序還原 Layer 1 到 Layer 5。

### Layer 1: runtime snapshot

優先使用：

* `runtime/<bot>/home.tar.gz`

若找不到，退回舊 key：

* `<bot>-home.tar.gz`

這一層通常包含：

* 登入憑證
* sqlite / cache
* runtime 生成檔案
* 使用者家目錄內的歷史狀態

### Layer 2: common

從：

* `layers/2-common/`

同步到：

* `$HOME/`

這一層通常放：

* 共用工具說明 `TOOLS.md`
* `.openab/` 下的共用 helper script

### Layer 3: backend

從：

* `layers/3-backend/<backend>/`

同步到：

* `$HOME/`

這一層通常放：

* backend 專屬 `.profile`
* `agentauth` alias
* backend 共用設定

### Layer 4: bot

從：

* `layers/4-bot/<bot>/`

同步到：

* `$HOME/`

這一層通常放：

* bot 專屬 steering
* bot 專屬靜態設定

### Layer 5: AGENTS

最後複製：

* `layers/5-agents/AGENTS.md`

到：

* `$HOME/AGENTS.md`

這一層永遠最後覆蓋，確保全域協作規則是最終版本。

## 權限與執行位元補正

S3 還原後，某些檔案的 executable bit 可能不可靠，因此 `pre-boot.sh` 會額外執行：

* `chmod +x "$HOME/bin/"*`
* `chmod +x "$HOME/bin/ghp"`
* `chmod +x "$HOME/.openab/"*.sh`

另外還會建立：

* `gh -> ghp` 的 symlink

這讓容器內的 `gh` CLI 會走專案預期的代理 shim。

## `pre-shutdown.sh` 的責任

`pre-shutdown.sh` 的工作單純很多：把最新 runtime state 打包回 S3。

流程：

1. 解析 `HOME` 與 `STATE_BUCKET`
2. 找出可用的 `aws` CLI
3. 若找不到 `aws`，直接略過備份
4. 把 `$HOME` 打包成 tarball
5. 上傳到 `s3://$STATE_BUCKET/runtime/<bot>/home.tar.gz`

## Runtime 備份排除規則

為了避免把大型工具快取與不必要內容一起打包，`pre-shutdown.sh` 會排除：

* `./aws-cli`
* `./bin/aws`
* `./.cache`
* `./.npm`
* `./node_modules`
* `./.rustup`
* `./.cargo`
* `./.local/share/uv/cache`
* `./.local/aws-cli`
* `./.openab/logs`
* `./.openab/tmp`
* `./tmp`

因此 Layer 1 的定位不是「完整 home 複製」，而是「保留實際需要延續的 runtime state」。

## 與其他文件的責任邊界

* `docs/state_layers.md`
  * 說明 layer 模型與 S3 路徑設計
* `docs/hooks_gist_sync.md`
  * 說明 repo hook 如何同步到 gist 與更新 hash
* 本文件
  * 說明 hook 在容器啟動與關閉時真正做了哪些事

## 常見判讀方式

當容器異常時，可用這些症狀反推問題位置：

* 缺少 `TOOLS.md` 或 helper script
  * 優先檢查 Layer 2 是否同步
* `agentauth` 不存在或 backend 行為不對
  * 優先檢查 Layer 3 是否同步
* 人設或 bot 專屬規則缺失
  * 優先檢查 Layer 4 是否同步
* 全域 AGENTS 規則不是最新
  * 優先檢查 Layer 5 是否同步
* 登入狀態或歷史 session 遺失
  * 優先檢查 Layer 1 runtime snapshot 是否成功下載或上傳
