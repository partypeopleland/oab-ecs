# AWS 基礎架構初始化指南 (AWS Infrastructure)

本文件指引 AI Agent 如何驗證、探測並建立 OpenAB 部署所需的 AWS 基礎設施。

---

## 📋 基礎設施清單
部署 Fargate 服務必須確保 AWS 中具備：
1. **ECS Cluster** (預設: `openab-cluster`)
2. **IAM Task Execution Role** (預設: `openab-task-execution-role`)
3. **IAM Task Role** (預設: `openab-task-role`)
4. **Security Group** (預設: `openab-sg`)
5. **Subnets** (至少 2 個與 Security Group 同個 VPC 的子網路)
6. **S3 State Bucket** (用於存放 Bot 狀態備份與 uv 工具快取)

---

## ⚙️ AI Agent 執行步驟

### Step 1. 認證檢查
執行以下指令檢查是否有 AWS 存取權限：
```bash
aws sts get-caller-identity
```
* **失敗處理**：若未登入，輸出提示教導人類使用者執行 `aws configure`。

### Step 2. 檢查工具是否安裝
確認 `yq` 已安裝（部署腳本依賴此工具）：
```bash
yq --version
```
* **失敗處理**：若未安裝，提示安裝：`https://github.com/mikefarah/yq`

### Step 3. 初始化 AWS 環境資源 (ops/aws-init.sh)
檢查本地是否存在 `aws-env.yaml`：
* **若不存在**：
  1. 讀取並確認 [aws-init.yaml](../ops/aws-init.yaml) 內的自訂名稱與網路覆寫（例如 `cluster_name`、`vpc_id`、`subnet_ids`）。
  2. 執行初始化腳本：
     ```bash
     ops/aws-init.sh
     ```
  3. 該腳本會檢查並自動建立上述所有缺失的 AWS 資源（冪等操作，已存在則跳過），並自動生成本地的 `aws-env.yaml`。
  4. 同時會將 uv 下載包快取至 S3，加速後續容器啟動。

### `aws-init.yaml` 的網路覆寫
若你的 AWS 環境不是標準 default VPC，或你想固定使用特定子網，可以在 [aws-init.yaml](../ops/aws-init.yaml) 內填：

```yaml
vpc_id: vpc-xxxxxxxx
subnet_ids:
  - subnet-aaaaaaaa
  - subnet-bbbbbbbb
```

`aws-init.sh` 會優先使用這組覆寫值；如果沒有填，再回到既有的自動探測流程。

---

## 📄 輸出檔案結構 (`aws-env.yaml`)
`ops/aws-init.sh` 執行成功後會產生 `aws-env.yaml`（此檔案受 Git 忽略）。其內容格式如下：
```yaml
cluster: openab-cluster
execution_role_arn: arn:aws:iam::<ACCOUNT_ID>:role/openab-task-execution-role
task_role_arn: arn:aws:iam::<ACCOUNT_ID>:role/openab-task-role
state_bucket: openab-state-bucket-<ACCOUNT_ID>
region: us-east-1

subnets: |
  - subnet-01cfe91e073a25b53
  - subnet-035b826309cadd7f7

security_groups: |
  - sg-007e9eeb4a84d7b83
```
* **AI 驗證動作**：確認 `aws-env.yaml` 正確產生，且欄位皆非空值後，方可進入部署程序。

---

## 🔄 uv 工具快取機制
容器啟動時，`pre-boot.sh` 會優先自 S3 快取路徑 `cache/uv-0.11.21-x86_64-unknown-linux-musl.tar.gz` 複製並安裝 `uv`。若快取不存在，則改下載固定版本 `0.11.21`，並先比對官方提供的 `sha256` 後再安裝，之後才會寫回快取。
*(註：AWS CLI 改為每次直接下載固定版本 `2.35.7` 再安裝。)*
