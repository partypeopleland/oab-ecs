# AWS Secrets Manager 密鑰管理指南 (AWS Secrets Manager)

本文件指引 AI Agent 如何建立、讀取、更新、刪除 OpenAB 機器人所需的敏感密鑰（如 `DISCORD_BOT_TOKEN`、`GH_TOKEN`），並完成權限檢驗。

---

## 🔒 Secrets Manager 密鑰生命週期 (CRUD)

### 1. 建立密鑰 (Create)
若特定 Bot 的密鑰路徑（如 `openab/oab-ghost`）在 AWS 中不存在，AI Agent 或開發人員應建立它。我們提供了兩種建立方式：

#### 🛠️ 方法 A：使用自動化建立腳本 (推薦)
專案中提供了一個便捷的自動化 Bash 腳本 [ops/create-secret.sh](file:///home/art/oab-ecs/ops/create-secret.sh)。它會自動讀取 [ops/aws-env.yaml](file:///home/art/oab-ecs/ops/aws-env.yaml) 中的 AWS Region 設定，並自動將密鑰名稱格式化為 `openab/oab-<bot_name>`。

**使用指令：**
```bash
ops/create-secret.sh <bot名稱> <DISCORD_BOT_TOKEN>
```

* **參數說明**：
  * `<bot名稱>`：Bot 的名稱（例如 `spirit` 或 `ghost`），腳本會將其自動串接為 `openab/oab-<bot名稱>`。
  * `<DISCORD_BOT_TOKEN>`：該 Bot 實際使用的 Discord Bot Token。
* **使用範例**：
  ```bash
  ops/create-secret.sh spirit MTIzNDU2Nzg5...
  ```

#### 💻 方法 B：手動使用 AWS CLI 指令
您也可以手動執行 AWS CLI 指令來建立密鑰：
```bash
aws secretsmanager create-secret \
  --name "openab/oab-ghost" \
  --description "OpenAB Bot Configuration Secrets for ghost" \
  --secret-string '{"DISCORD_BOT_TOKEN":"your_real_discord_bot_token_here","GH_TOKEN":"ghp_your_real_github_token_here"}' \
  --region us-east-1
```

### 2. 讀取密鑰 (Read)
若要讀取現有密鑰值：
```bash
aws secretsmanager get-secret-value --secret-id "openab/oab-ghost" --region us-east-1
```
* **AI 處理**：解析輸出 JSON 中的 `SecretString`，以 JSON 解析取得物件並讀取其中所需欄位，例如 `DISCORD_BOT_TOKEN` 與 `GH_TOKEN`。

### 3. 更新密鑰 (Update)
更新密鑰欄位時，應先執行 `Read` 取得當前完整 JSON，合併更新欄位後，再整份寫回，避免覆寫其他共存的 Key：
```bash
aws secretsmanager put-secret-value \
  --secret-id "openab/oab-ghost" \
  --secret-string '{"DISCORD_BOT_TOKEN":"new_discord_bot_token_here","GH_TOKEN":"ghp_new_github_token_here"}' \
  --region us-east-1
```

### 4. 刪除密鑰 (Delete)
當機器人退役時，為確保能即時重新建立，執行強制立刻刪除：
```bash
aws secretsmanager delete-secret --secret-id "openab/oab-ghost" --force-delete-without-recovery --region us-east-1
```

---

## 🔑 IAM Task Role 權限檢驗
Fargate 容器是在運行時直接向 AWS 請求解密。AI Agent 應審查 `openab-task-role`，確保其附加了包含以下 Statement 的 Policy：
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:us-east-1:<ACCOUNT_ID>:secret:openab/*"
    }
  ]
}
```

---

## 🔗 OpenAB 設定檔整合
在部署時，AI Agent 在模板產生的 `config.toml` 中，需使用以下語法指向該 Secret：
```toml
[secrets.refs]
discord_bot_token = "aws-sm://{{secret_path}}#DISCORD_BOT_TOKEN"
gh_token = "exec:///home/agent/.openab/get-optional-gh-token.sh {{secret_path}}"

[discord]
bot_token = "${secrets.discord_bot_token}"

[agent]
env = { GH_TOKEN = "${secrets.gh_token}" }
```
* **變數對照**：`{{secret_path}}` 將會被替換為 Bot 的密鑰路徑（如 `openab/oab-ghost`）。
* **用途說明**：`GH_TOKEN` 會透過 `[agent].env` 傳給 agent subprocess，供容器內的 `gh` 直接使用。
* **可選行為**：`DISCORD_BOT_TOKEN` 仍是必填；`GH_TOKEN` 會由輔助腳本在 `pre_boot` 完成後嘗試從同一個 Secret 讀取。若不存在、讀取失敗或沒有權限，會回傳空字串並略過，不會阻止 OpenAB 啟動。
* **腳本位置**：輔助腳本應放在 `state/shared/common/.openab/get-optional-gh-token.sh`，並先用 `ops/saveBucket.sh <bot_name>` 同步到 S3，讓 `pre_boot` 還原到容器內的 `/home/agent/.openab/get-optional-gh-token.sh`。
