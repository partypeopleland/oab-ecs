# 🛠️ Agent 專屬工具清單 (bin/)
在當前運行的容器中，系統已經在 `/home/agent/bin/` 底下為您部署了以下核心工具。您可以在終端機或透過程式直接執行它們：

1. **`aws` (AWS CLI)**：AWS 官方命令列工具，可用於讀取與寫入 S3 Bucket、與 CloudWatch Logs 互動等。
2. **`gh` / `ghp` (GitHub CLI)**：GitHub 官方命令列工具，已配置 ghpool 代理，可用於存取 GitHub 倉庫。
3. **`uv` (Python 環境與套件管理器)**：極速 Python 工具，可用於自動安裝/切換 Python 版本（如 `uv python install`）及管理虛擬環境（如 `uv run`）。
