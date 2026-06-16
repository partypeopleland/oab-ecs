# AWS Secrets Manager 密鑰管理指南 (AWS Secrets Manager)

本文件指引 AI Agent 如何建立、讀取、更新、刪除 OpenAB 機器人所需的敏感密鑰（如 `DISCORD_BOT_TOKEN`），並完成權限檢驗。

---

## 🔒 Secrets Manager 密鑰生命週期 (CRUD)

### 1. 建立密鑰 (Create)
若特定 Bot 的密鑰路徑（如 `openab/oab-ghost`）在 AWS 中不存在，AI Agent 應建立它：
```bash
aws secretsmanager create-secret \
  --name "openab/oab-ghost" \
  --description "OpenAB Bot Configuration Secrets for ghost" \
  --secret-string '{"DISCORD_BOT_TOKEN":"your_real_discord_bot_token_here"}' \
  --region us-east-1
```

### 2. 讀取密鑰 (Read)
若要讀取現有密鑰值：
```bash
aws secretsmanager get-secret-value --secret-id "openab/oab-ghost" --region us-east-1
```
* **AI 處理**：解析輸出 JSON 中的 `SecretString`，以 JSON 解析取得物件並讀取其中的 `DISCORD_BOT_TOKEN`。

### 3. 更新密鑰 (Update)
更新密鑰欄位時，應先執行 `Read` 取得當前完整 JSON，合併更新欄位後，再整份寫回，避免覆寫其他共存的 Key：
```bash
aws secretsmanager put-secret-value \
  --secret-id "openab/oab-ghost" \
  --secret-string '{"DISCORD_BOT_TOKEN":"new_discord_bot_token_here"}' \
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

[discord]
bot_token = "${secrets.discord_bot_token}"
```
* **變數對照**：`{{secret_path}}` 將會被替換為 Bot 的密鑰路徑（如 `openab/oab-ghost`）。
