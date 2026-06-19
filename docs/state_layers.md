# State Layers 模型

本 repo 把 bot 狀態分成 5 層，目的只有一個：把「容器運行中自然生成的狀態」和「repo 內人工維護的靜態內容」分開。

這樣可以避免：

- 上傳靜態檔時覆蓋 runtime 狀態
- 還原 runtime 時把共用規則弄丟
- 不同 backend / bot 的覆蓋順序混亂

## 核心原則

1. Layer 1 是 runtime snapshot，不在 repo 內編輯。
2. Layer 2-5 是靜態 overlay，來源都在 `state/layers/`。
3. 數字就是覆蓋順序，後面的層會蓋掉前面的內容。

## 一眼看懂覆蓋順序

```text
                  /\                      
                 /L5\ ----------------------> L5: final AGENTS.md               (state/layers/5-agents/AGENTS.md)
                /----\
               /  L4  \ --------------------> bot-only static content           (state/layers/4-bot/<bot>/)
              /--------\                   
             /    L3    \ ------------------> backend shared content            (state/layers/3-backend/<backend>/)
            /------------\                   
           /      L2      \ ----------------> all bots shared content           (state/layers/2-common/)
          /----------------\                 
         /        L1        \ --------------> runtime snapshot / login / cache  (s3://<bucket>/runtime/<bot>/home.tar.gz)
        /--------------------\               

bottom -> top = restore first -> override later
```

這張圖表示容器開機時的疊層順序：

- Layer 1 在最底部，先還原 runtime snapshot
- Layer 2 到 Layer 4 逐層覆蓋共用、backend 共用、bot 專屬內容
- Layer 5 最後覆蓋 `AGENTS.md`

越上層代表越晚套用，因此同名檔案會以較上層為準。

## 五層定義

| Layer | 用途 | repo 路徑 | S3 路徑 | 誰負責寫入 |
|---|---|---|---|---|
| 1 | runtime snapshot，例如登入憑證、sqlite、cache、session | 無 | `runtime/<bot>/home.tar.gz` | `pre-shutdown.sh` |
| 2 | 所有 bot 共用的靜態內容 | `state/layers/2-common/` | `layers/2-common/` | `ops/upload-layers.sh` |
| 3 | 同 backend 共用的靜態內容 | `state/layers/3-backend/<backend>/` | `layers/3-backend/<backend>/` | `ops/upload-layers.sh` |
| 4 | bot 專屬靜態內容 | `state/layers/4-bot/<bot>/` | `layers/4-bot/<bot>/` | `ops/upload-layers.sh` |
| 5 | 所有 bot 共用的最終 `AGENTS.md` | `state/layers/5-agents/AGENTS.md` | `layers/5-agents/AGENTS.md` | `ops/upload-layers.sh` |

## 開機還原順序

`pre-boot.sh` 會依序做：

1. 還原 Layer 1 `runtime/<bot>/home.tar.gz`
2. sync Layer 2 到 `$HOME/`
3. sync Layer 3 到 `$HOME/`
4. sync Layer 4 到 `$HOME/`
5. 複製 Layer 5 到 `$HOME/AGENTS.md`

所以：

- 共用檔案可被 backend 或 bot 專屬版本覆蓋
- `AGENTS.md` 永遠最後覆蓋，確保容器內拿到的是最終規則

```text
Layer 2: everyone
    overridden by
Layer 3: same backend
    overridden by
Layer 4: this bot only
    overridden by
Layer 5: final AGENTS rule
```

相容性：

- 新 key：`runtime/<bot>/home.tar.gz`
- 舊 key：`<bot>-home.tar.gz`

目前 `pre-boot.sh` 與 `ops/restore-layer1.sh` 都接受舊 key 作為 fallback。

## `upload-layers.sh` 的責任邊界

`ops/upload-layers.sh <bot>` 只處理 Layer 2-5：

- `state/layers/2-common/` -> `layers/2-common/`
- `state/layers/3-backend/<backend>/` -> `layers/3-backend/<backend>/`
- `state/layers/4-bot/<bot>/` -> `layers/4-bot/<bot>/`
- `state/layers/5-agents/AGENTS.md` -> `layers/5-agents/AGENTS.md`

它不應碰 Layer 1。

另外要注意：

- Layer 2-4 使用 `aws s3 sync --delete`
- 刪掉本地檔案後再上傳，S3 端對應檔案也會被刪除

```text
repo state/layers/* --upload--> S3 layers/*

repo does NOT upload:
  runtime/<bot>/home.tar.gz

runtime/<bot>/home.tar.gz is written by:
  pre-shutdown.sh
```

## 什麼該放哪一層

Layer 2 常見內容：

- `TOOLS.md`
- `.openab/` 下的共用 helper script

Layer 3 常見內容：

- backend 專屬 `.profile`
- `agentauth` alias
- backend 共用設定

Layer 4 常見內容：

- bot 專屬 steering
- bot 專屬規則
- bot 專屬靜態檔

Layer 5 常見內容：

- 給容器內 agent 的全域協作規則

## 不要放進 Layer 2-5 的東西

以下通常屬於 Layer 1 runtime，不應手動塞進 `state/layers/`：

- `.aws/`
- `.cache/`
- sqlite 資料檔
- runtime 生成的 session / login 檔
- `.local/share/...` 類工具狀態

## 本地目錄範例

```text
state/
  layers/
    2-common/
      TOOLS.md
      .openab/
    3-backend/
      agy/
      kiro/
    4-bot/
      ghost/
      spirit/
    5-agents/
      AGENTS.md
```
