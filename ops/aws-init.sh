#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/aws-env.yaml"
DEFAULTS_FILE="$SCRIPT_DIR/aws-init.yaml"

# 讀取預設名稱，如果檔案不存在或無設定則套用 fallback 預設值
get_default() {
  local key=$1
  if [ -f "$DEFAULTS_FILE" ]; then
    grep -w "$key" "$DEFAULTS_FILE" \
      | head -n 1 \
      | sed -E "s/[[:space:]]*$key:[[:space:]]*//; s/^[\"']//; s/[\"']$//"
  else
    echo ""
  fi
}

CLUSTER_NAME=$(get_default "cluster_name")
[ -z "$CLUSTER_NAME" ] && CLUSTER_NAME="openab-cluster"

EXEC_ROLE_NAME=$(get_default "execution_role_name")
[ -z "$EXEC_ROLE_NAME" ] && EXEC_ROLE_NAME="openab-task-execution-role"

TASK_ROLE_NAME=$(get_default "task_role_name")
[ -z "$TASK_ROLE_NAME" ] && TASK_ROLE_NAME="openab-task-role"

SG_NAME=$(get_default "security_group_name")
[ -z "$SG_NAME" ] && SG_NAME="openab-sg"

echo "=== OpenAB ECS Environment Initializer ==="
echo "正在檢查 AWS CLI 驗證狀態..."

# 檢查 AWS CLI 登入狀態
if ! aws sts get-caller-identity --query "Arn" --output text >/dev/null 2>&1; then
  echo "錯誤: AWS CLI 尚未驗證或登入。請先執行 'aws configure' 設定憑證。"
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
REGION=$(aws configure get region || echo "us-east-1")
echo "✓ AWS CLI 已通過驗證。帳號 ID: $ACCOUNT_ID, 預設區域: $REGION"

STATE_BUCKET_NAME=$(get_default "state_bucket_name")
[ -z "$STATE_BUCKET_NAME" ] && STATE_BUCKET_NAME="openab-state-bucket-$ACCOUNT_ID"

# 建立暫存信任 Policy 檔案以供建立 IAM Role 使用
cat << 'EOF' > /tmp/ecs-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# ==========================================
# 1. 確保 ECS Cluster 存在
# ==========================================
echo "------------------------------------------"
echo "1. 檢查 ECS Cluster ($CLUSTER_NAME)..."
cluster_status=$(aws ecs describe-clusters --clusters "$CLUSTER_NAME" --query "clusters[0].status" --output text 2>/dev/null || echo "MISSING")

if [ "$cluster_status" = "ACTIVE" ]; then
  echo "✓ ECS Cluster '$CLUSTER_NAME' 已經存在。略過建立。"
  cluster="$CLUSTER_NAME"
else
  echo "⚠️ ECS Cluster '$CLUSTER_NAME' 不存在。正在建立..."
  aws ecs create-cluster --cluster-name "$CLUSTER_NAME" >/dev/null
  cluster="$CLUSTER_NAME"
  echo "✓ ECS Cluster '$CLUSTER_NAME' 建立成功。"
fi

# ==========================================
# 2. 確保 IAM Roles 存在並具備正確權限
# ==========================================
echo "------------------------------------------"
echo "2. 檢查 Task Execution Role ($EXEC_ROLE_NAME)..."
if aws iam get-role --role-name "$EXEC_ROLE_NAME" >/dev/null 2>&1; then
  execution_role=$(aws iam get-role --role-name "$EXEC_ROLE_NAME" --query "Role.Arn" --output text)
  echo "✓ IAM Role '$EXEC_ROLE_NAME' 已經存在。略過建立。"
else
  echo "⚠️ IAM Role '$EXEC_ROLE_NAME' 不存在。正在建立..."
  execution_role=$(aws iam create-role --role-name "$EXEC_ROLE_NAME" --assume-role-policy-document file:///tmp/ecs-trust-policy.json --query "Role.Arn" --output text)
  echo "正在附加 AmazonECSTaskExecutionRolePolicy 權限..."
  aws iam attach-role-policy --role-name "$EXEC_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
  echo "✓ IAM Role '$EXEC_ROLE_NAME' 建立並授權成功。"
fi

echo "檢查 Task Role ($TASK_ROLE_NAME)..."
if aws iam get-role --role-name "$TASK_ROLE_NAME" >/dev/null 2>&1; then
  task_role=$(aws iam get-role --role-name "$TASK_ROLE_NAME" --query "Role.Arn" --output text)
  echo "✓ IAM Role '$TASK_ROLE_NAME' 已經存在。略過建立。"
else
  echo "⚠️ IAM Role '$TASK_ROLE_NAME' 不存在。正在建立..."
  task_role=$(aws iam create-role --role-name "$TASK_ROLE_NAME" --assume-role-policy-document file:///tmp/ecs-trust-policy.json --query "Role.Arn" --output text)
  echo "✓ IAM Role '$TASK_ROLE_NAME' 建立成功。"
fi

# 建立/更新 Secrets Manager 與 S3 權限 Policy
cat << EOF > /tmp/openab-task-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:$REGION:$ACCOUNT_ID:secret:openab/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::$STATE_BUCKET_NAME",
        "arn:aws:s3:::$STATE_BUCKET_NAME/*"
      ]
    }
  ]
}
EOF
echo "正在附加/更新 Task Role 權限 (Secrets Manager & S3)..."
aws iam put-role-policy --role-name "$TASK_ROLE_NAME" --policy-name openab-task-policy --policy-document file:///tmp/openab-task-policy.json
rm -f /tmp/openab-task-policy.json
echo "✓ IAM Role '$TASK_ROLE_NAME' 授權更新成功。"

# 清理信任 Policy 暫存檔
rm -f /tmp/ecs-trust-policy.json

# ==========================================
# 3. 確保 Security Group 存在
# ==========================================
echo "------------------------------------------"
echo "3. 檢查 Security Group ($SG_NAME)..."
sg=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)

if [ -n "$sg" ] && [ "$sg" != "None" ]; then
  echo "✓ Security Group '$SG_NAME' ($sg) 已經存在。略過建立。"
  vpc_id=$(aws ec2 describe-security-groups --group-ids "$sg" --query "SecurityGroups[0].VpcId" --output text)
else
  echo "⚠️ Security Group '$SG_NAME' 不存在。正在尋找預設 VPC..."
  vpc_id=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text 2>/dev/null || true)
  if [ -z "$vpc_id" ] || [ "$vpc_id" = "None" ]; then
    vpc_id=$(aws ec2 describe-vpcs --query "Vpcs[0].VpcId" --output text 2>/dev/null || true)
  fi
  
  if [ -n "$vpc_id" ] && [ "$vpc_id" != "None" ]; then
    echo "在 VPC '$vpc_id' 中建立 Security Group '$SG_NAME'..."
    sg=$(aws ec2 create-security-group --group-name "$SG_NAME" --description "Security group for OpenAB" --vpc-id "$vpc_id" --query "GroupId" --output text)
    echo "✓ Security Group '$SG_NAME' ($sg) 建立成功。"
  else
    echo "錯誤: 無法找到任何可用 VPC，無法建立 Security Group。"
    exit 1
  fi
fi

# ==========================================
# 4. 探測對應 VPC 下的 Subnets
# ==========================================
echo "------------------------------------------"
echo "4. 正在探測 VPC ($vpc_id) 的 Subnets..."
subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" --query "Subnets[*].SubnetId" --output text | tr '\t' '\n' | head -n 2)

if [ -z "$subnets" ]; then
  echo "錯誤: 在 VPC '$vpc_id' 中找不到任何 Subnets。"
  exit 1
fi
echo "✓ 已選擇 Subnets:"
echo "$subnets" | sed 's/^/  - /'

# ==========================================
# 5. 確保 S3 State Bucket 存在
# ==========================================
echo "------------------------------------------"
echo "5. 檢查 S3 State Bucket ($STATE_BUCKET_NAME)..."
if aws s3api head-bucket --bucket "$STATE_BUCKET_NAME" >/dev/null 2>&1; then
  echo "✓ S3 Bucket '$STATE_BUCKET_NAME' 已經存在。略過建立。"
else
  echo "⚠️ S3 Bucket '$STATE_BUCKET_NAME' 不存在。正在建立..."
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$STATE_BUCKET_NAME" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$STATE_BUCKET_NAME" --region "$REGION" --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  fi
  echo "✓ S3 Bucket '$STATE_BUCKET_NAME' 建立成功。"
fi

# ==========================================
# 6. 快取 AWS CLI 至 S3 (加速 pre-boot)
# ==========================================
echo "------------------------------------------"
echo "6. 快取 AWS CLI 安裝包至 S3..."
AWSCLI_CACHE_KEY="cache/awscli-linux-x86_64.zip"
if aws s3api head-object --bucket "$STATE_BUCKET_NAME" --key "$AWSCLI_CACHE_KEY" >/dev/null 2>&1; then
  echo "✓ AWS CLI 快取已存在於 S3。略過上傳。"
else
  echo "正在下載 AWS CLI 安裝包..."
  TMP_ZIP="/tmp/awscli-cache.zip"
  curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "$TMP_ZIP"
  echo "正在上傳至 S3..."
  aws s3 cp "$TMP_ZIP" "s3://$STATE_BUCKET_NAME/$AWSCLI_CACHE_KEY" --quiet
  rm -f "$TMP_ZIP"
  echo "✓ AWS CLI 快取上傳成功。"
fi

# ==========================================
# 7. 產生環境設定檔
# ==========================================
echo "------------------------------------------"
cat << EOF > "$ENV_FILE"
# aws-env.yaml
# 自動產生的 AWS 全域環境設定，由 aws-init.sh 產生。
# 若有需要，您可以隨時手動修改此檔案中的值。

cluster: $cluster
execution_role_arn: $execution_role
task_role_arn: $task_role
state_bucket: $STATE_BUCKET_NAME
region: $REGION

subnets: |
$(echo "$subnets" | sed 's/^/  - /')

security_groups: |
  - sg
EOF

# 替換 sg 預留位置，避免 shell 轉義問題
sed -i "s@  - sg@  - $sg@g" "$ENV_FILE"

echo "==========================================="
echo "✓ 成功產生環境設定檔: $ENV_FILE"
echo "==========================================="
