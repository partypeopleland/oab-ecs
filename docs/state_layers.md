# 狀態分層與 S3 路徑模型 (State Layers)

本文件定義本 repo 對 Bot 狀態的分層模型、本地目錄結構，以及對應的 S3 路徑。目標是讓「容器 runtime 狀態」與「人工維護的靜態 overlay」完全分離，避免 `upload-layers.sh` 覆蓋 runtime 備份。

## 設計原則

* **Layer 1 是 runtime snapshot**：只允許 `pre-boot.sh` / `pre-shutdown.sh` 讀寫，不提供本地人工同步入口。
* **Layer 2-5 是靜態 overlay**：全部放在 `state/layers/` 下，同層級、同深度、同命名規則。
* **命名以數字排序**：直接反映開機時的覆蓋順序，避免 `shared/common`、`shared/kiro`、`state/spirit` 這種深度與語意不一致的結構。

## Layer 定義

1. **Layer 1: runtime**
   * 用途：容器真實狀態，包含登入憑證、sqlite、cache、runtime 產生的檔案。
   * 本地路徑：無。
   * S3 路徑：`runtime/<bot>/home.tar.gz`
   * 只由 `pre-shutdown.sh` 寫入，`pre-boot.sh` / `restore-layer1.sh` 還原。

2. **Layer 2: common**
   * 用途：所有 Bot 共用的靜態資源。
   * 本地路徑：`state/layers/2-common/`
   * S3 路徑：`layers/2-common/`

3. **Layer 3: backend**
   * 用途：同 backend 類型共用的靜態資源。
   * 本地路徑：`state/layers/3-backend/<backend>/`
   * S3 路徑：`layers/3-backend/<backend>/`

4. **Layer 4: bot**
   * 用途：Bot 自身的靜態資源，例如專屬人設。
   * 本地路徑：`state/layers/4-bot/<bot>/`
   * S3 路徑：`layers/4-bot/<bot>/`

5. **Layer 5: agents**
   * 用途：全域 `AGENTS.md`，永遠最後覆蓋。
   * 本地路徑：`state/layers/5-agents/AGENTS.md`
   * S3 路徑：`layers/5-agents/AGENTS.md`

## pre-boot 還原順序

`pre-boot.sh` 依序執行：

1. 從 `runtime/<bot>/home.tar.gz` 還原 runtime snapshot
2. `layers/2-common/` sync 到 `$HOME/`
3. `layers/3-backend/<backend>/` sync 到 `$HOME/`
4. `layers/4-bot/<bot>/` sync 到 `$HOME/`
5. `layers/5-agents/AGENTS.md` 複製到 `$HOME/AGENTS.md`

> 相容性說明：為了平滑遷移，`pre-boot.sh` 與 `restore-layer1.sh` 目前仍接受舊版 runtime key `<bot>-home.tar.gz` 作為 fallback。新的寫入路徑一律使用 `runtime/<bot>/home.tar.gz`。

## upload-layers 的責任邊界

`ops/upload-layers.sh <bot>` 只負責同步 Layer 2-5：

* `state/layers/2-common/` -> `layers/2-common/`
* `state/layers/3-backend/<backend>/` -> `layers/3-backend/<backend>/`
* `state/layers/4-bot/<bot>/` -> `layers/4-bot/<bot>/`
* `state/layers/5-agents/AGENTS.md` -> `layers/5-agents/AGENTS.md`

`upload-layers.sh` **不得**寫入 Layer 1 runtime snapshot。

## 本地目錄範例

```text
state/
  layers/
    2-common/
      TOOLS.md
      .openab/
    3-backend/
      kiro/
        .profile
      agy/
        .profile
    4-bot/
      spirit/
        steering/
      ghost/
        steering/
    5-agents/
      AGENTS.md
```

## 使用建議

* 想保留登入狀態、sqlite、cache：依賴 Layer 1 runtime snapshot。
* 想從 repo 更新規則、工具說明、backend profile、bot人設：編輯 `state/layers/` 後執行 `ops/upload-layers.sh <bot>`。
* 不要把 `.aws/`、`.local/share/kiro-cli/` 這類 runtime 檔案放進 Layer 2-5。
