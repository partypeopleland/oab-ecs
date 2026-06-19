# Hook 與 Runtime 行為

這份文件只講 hook 本身做了什麼。Layer 模型與路徑請看 [state_layers.md](./state_layers.md)。

## 生命週期

容器流程分成三段：

1. `pre_boot`
2. OpenAB 主程式運行
3. `pre_shutdown`

```text
container start
     |
     v
 pre_boot
     |
     v
 OpenAB runtime
     |
     v
pre_shutdown
     |
     v
container stop
```

`pre_boot` 失敗會中止啟動。`pre_shutdown` 失敗通常不會影響已結束的容器，但可能造成最新 runtime snapshot 沒有備份回 S3。

## `pre-boot.sh`

目標是把 `/home/agent` 還原成可工作的狀態。

### 會做的事

1. 設定基本環境
- 設定 `HOME`
- 建立 `$HOME/bin`
- 關閉 `AWS_PAGER`

2. 安裝固定版本 AWS CLI
- 版本：`2.35.7`
- 每次都從官方來源重新下載安裝
- 不依賴 image 內預裝版本

3. 載入或下載固定版本 `uv`
- 版本：`0.11.21`
- 先嘗試讀取 `s3://$STATE_BUCKET/cache/uv-0.11.21-x86_64-unknown-linux-musl.tar.gz`
- 快取不存在時改從 GitHub release 下載並驗證 SHA256
- 首次下載成功後會回寫 S3 快取

4. 還原 Layer 1-5
- 順序請以 [state_layers.md](./state_layers.md) 為準

5. 修正還原後的可執行權限
- `chmod +x "$HOME/bin/"*`
- `chmod +x "$HOME/bin/ghp"`
- `chmod +x "$HOME/.openab/"*.sh`

6. 建立 `gh -> ghp` symlink
- 讓容器內 `gh` 走 repo 預期的 shim

```text
S3/runtime + S3/layers
          |
          v
      pre-boot.sh
          |
          +--> install aws
          +--> restore/download uv
          +--> restore Layer 1-5
          +--> fix executable bits
          |
          v
   /home/agent becomes runnable
```

## `pre-shutdown.sh`

目標很單純：把最新 runtime state 打包回 S3。

流程：

1. 取得可用的 `aws` CLI
2. 若找不到 `aws`，直接略過備份
3. 打包 `$HOME`
4. 上傳到 `s3://$STATE_BUCKET/runtime/<bot>/home.tar.gz`

```text
/home/agent
    |
    v
pre-shutdown.sh
    |
    +--> exclude caches/tmp
    +--> tar.gz
    +--> upload runtime/<bot>/home.tar.gz
```

## Layer 1 不是完整 home 備份

`pre-shutdown.sh` 會排除大型快取與暫存目錄，例如：

- `./aws-cli`
- `./bin/aws`
- `./.cache`
- `./.npm`
- `./node_modules`
- `./.rustup`
- `./.cargo`
- `./.local/share/uv/cache`
- `./.local/aws-cli`
- `./.openab/logs`
- `./.openab/tmp`
- `./tmp`

所以 Layer 1 的定位是「保留需要延續的 runtime 狀態」，不是完整複製整個 home。

## 什麼時候需要讀這份文件

- 你要改 `hooks/pre-boot.sh` 或 `hooks/pre-shutdown.sh`
- 你要理解為什麼 container 啟動前後會多出某些檔案
- 你在追查 uv / AWS CLI / 權限 / runtime snapshot 相關問題

## 常見問題對照

| 症狀 | 優先檢查 |
|---|---|
| `gh` 行為不如預期 | `ghp` shim 與 symlink 是否存在 |
| helper script 在容器內不能執行 | `pre-boot.sh` 的 `chmod` 補正是否有跑 |
| 冷啟動很慢 | `uv` 是否命中 S3 快取 |
| 登入狀態消失 | `pre-shutdown.sh` 是否成功上傳 runtime snapshot |
