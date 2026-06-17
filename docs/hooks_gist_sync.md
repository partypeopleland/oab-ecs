# Hook Gist 同步規範

本文件定義 `pre-boot` 與 `pre-shutdown` hook 的唯一來源、同步流程與維護規範。

---

## 單一來源原則

`hooks/` 目錄是 hook 腳本的唯一來源：

* [hooks/pre-boot.sh](../hooks/pre-boot.sh)
* [hooks/pre-shutdown.sh](../hooks/pre-shutdown.sh)

禁止在 `ops/` 或其他目錄維護第二份 hook 腳本副本，避免：

* gist 內容與 repo 內容漂移
* `bots.yaml` 的 SHA-256 與遠端內容不一致
* deploy 時出現 `hook sha256 mismatch`

---

## deploy 實際使用的來源

ECS deploy 時，OpenAB 不會直接讀取 repo 內的 `hooks/` 檔案，而是讀取 [bots.yaml](../ops/bots.yaml) 中設定的：

* `pre_boot_url`
* `pre_boot_sha256`
* `pre_shutdown_url`
* `pre_shutdown_sha256`

也就是說：

1. repo 內編輯的是 `hooks/*.sh`
2. deploy 時實際下載的是 gist URL
3. `bots.yaml` 的 SHA-256 必須對應 gist 上的實際內容

因此，修改 `hooks/*.sh` 後，必須先同步到 gist，再 deploy。

---

## 標準流程

修改 hook 後，使用：

```bash
ops/sync-hook-gists.sh
```

此腳本會：

1. 以 `hooks/pre-boot.sh` 與 `hooks/pre-shutdown.sh` 為來源
2. 更新 `bots.yaml` 中設定的 gist
3. 驗證 gist 更新後的內容 SHA-256
4. 自動刷新 `bots.yaml` 內對應的 `pre_*_sha256`

若只想同步特定 bot，可指定 bot 名稱：

```bash
ops/sync-hook-gists.sh ghost
ops/sync-hook-gists.sh spirit
```

---

## 前置條件

執行同步腳本前，需具備：

* 已安裝 `gh`
* 已安裝 `yq`
* 已安裝 `curl`
* 已完成 `gh auth login`

腳本會使用目前登入的 GitHub 帳號權限更新 gist。

---

## 維護規則

1. hook 內容只改 `hooks/`
2. 改完先執行 `ops/sync-hook-gists.sh`
3. 確認 `ops/bots.yaml` 的 hash 已更新
4. 再執行 deploy

如果跳過 gist 同步，最常見的結果是：

* 容器啟動時 hook 驗證失敗
* 日誌出現 `hook sha256 mismatch`
