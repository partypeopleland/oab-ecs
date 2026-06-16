# 監控、日誌與容器偵錯指南 (Observability & Debugging)

本文件指引 AI Agent 在部署 OpenAB 機器人後，如何驗證服務運作狀態、讀取運作日誌，以及進入容器內部進行偵錯。

---

## 🔍 1. 驗證服務與任務狀態
部署完成後，AI Agent 應主動確認 ECS Service 是否順利啟動並處於穩定狀態。

* **使用 ecsctl 查詢**：
  ```bash
  ecsctl get openab-<bot_name>-service
  ```
* **使用 AWS CLI 查詢**：
  ```bash
  aws ecs list-tasks --cluster <cluster_name> --service-name openab-<bot_name>-service
  ```

---

## 📄 2. 檢視運行日誌 (Logs)
日誌是了解 Bot 是否成功登入 Discord 以及 `pre-boot.sh` 是否執行成功的關鍵。

* **使用 ecsctl 即時讀取日誌**：
  ```bash
  ecsctl log openab-<bot_name>-service
  ```
  *(此指令會自動從 AWS CloudWatch 串流讀取該 Service 的 Container Logs)*。
* **CloudWatch Log Group 路徑**：
  預設輸出至 `/ecs/openab-<bot_name>`。

---

## 💻 3. 進入容器進行即時偵錯 (Container Exec)
若 Bot 啟動異常或環境變數有問題，AI Agent 可以進入運行中的容器內執行偵錯：

* **執行進入容器指令**：
  ```bash
  ecsctl exec openab-cluster/openab-<bot_name>-service/openab-<bot_name>
  ```
* **容器內重要檢查點**：
  1. **檢查 `config.toml` 是否正確產生**：
     ```bash
     cat /home/agent/config.toml
     ```
  2. **檢查 AWS Secrets 是否正確解密並載入**：
     檢查 `config.toml` 中解析後的 Secrets 內容。
  3. **檢查環境變數**：
     執行 `env` 確保 `OPENAB_AGENT_NAME`、`OPENAB_BACKEND_AGENT` 與 `OPENAB_AGENT_COMMAND` 等變數已正確生效。
