#!/bin/bash
# aws-destroy.sh
# 停止並刪除 Bot 的 ECS 服務，可選清理 S3 狀態、Secrets Manager 及 CloudWatch 日誌。
set -e

usage() {
  cat <<'EOF'
用途:
  停止並刪除指定 bot 的 ECS service，並可選擇清理 state 與 secret。

使用方式:
  aws-destroy.sh <bot名稱> [--purge-state] [--purge-secret]

範例:
  ops/aws-destroy.sh ghost
  ops/aws-destroy.sh ghost --purge-state
  ops/aws-destroy.sh ghost --purge-state --purge-secret

選項:
  --purge-state    同時刪除 S3 中的 runtime 與 Layer 4 bot 靜態內容
  --purge-secret   同時刪除 AWS Secrets Manager 中的密鑰
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ -z "${1:-}" ]; then
  usage
  exit 1
fi

BOT_NAME=$1
PURGE_STATE=false
PURGE_SECRET=false

shift
while [ $# -gt 0 ]; do
  case "$1" in
    --purge-state)  PURGE_STATE=true ;;
    --purge-secret) PURGE_SECRET=true ;;
    *) echo "未知的參數: $1"; echo ""; usage; exit 1 ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/aws-env.yaml"
BOTS_FILE="$SCRIPT_DIR/bots.yaml"
SERVICE_NAME="openab-$BOT_NAME"
LOG_GROUP="/ecs/$SERVICE_NAME"

if [ ! -f "$ENV_FILE" ]; then
  echo "錯誤: 找不到 aws-env.yaml 檔案。"
  exit 1
fi

if [ ! -f "$BOTS_FILE" ]; then
  echo "錯誤: 找不到 bots.yaml 檔案。"
  exit 1
fi

# 使用 yq 讀取設定
if command -v yq &>/dev/null; then
  CLUSTER=$(yq eval '.cluster' "$ENV_FILE")
  STATE_BUCKET=$(yq eval '.state_bucket' "$ENV_FILE")
  SECRET_PATH=$(yq eval ".$BOT_NAME.secret_path" "$BOTS_FILE")
else
  echo "錯誤: 找不到 yq 工具。"
  exit 1
fi

echo "=== 刪除 Bot: $BOT_NAME ==="
echo "ECS Cluster: $CLUSTER"
echo "ECS Service: $SERVICE_NAME"
echo "S3 Bucket: $STATE_BUCKET"
echo "Secret Path: $SECRET_PATH"
echo "CloudWatch Log Group: $LOG_GROUP"
echo ""
echo "⚠️ 此操作將停止 ECS 服務。"
[ "$PURGE_STATE" = true ] && echo "⚠️ 將同時刪除 S3 狀態備份 (不可逆)！"
[ "$PURGE_SECRET" = true ] && echo "⚠️ 將同時刪除 Secrets Manager 密鑰 (不可逆)！"
echo ""
read -p "確認要繼續嗎？(y/N): " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
  echo "已取消。"
  exit 0
fi

# 1. 停止並刪除 ECS Service
echo ""
echo "[1/4] 停止 ECS Service..."
if aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE_NAME" --query "services[0].status" --output text 2>/dev/null | grep -q "ACTIVE"; then
  # 先將 desired count 設為 0
  aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE_NAME" --desired-count 0 >/dev/null 2>&1
  echo "✓ 已將 $SERVICE_NAME 的 desired count 設為 0。"

  # 等待任務停止
  echo "等待任務停止..."
  aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE_NAME" 2>/dev/null || true

  # 刪除服務
  aws ecs delete-service --cluster "$CLUSTER" --service "$SERVICE_NAME" --force >/dev/null 2>&1
  echo "✓ ECS Service '$SERVICE_NAME' 已刪除。"
else
  echo "ℹ️ ECS Service '$SERVICE_NAME' 不存在或已停止。"
fi

# 2. 刪除 CloudWatch Log Group
echo ""
echo "[2/4] 刪除 CloudWatch Log Group..."
if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --query "logGroups[?logGroupName=='$LOG_GROUP']" --output text 2>/dev/null | grep -q "$LOG_GROUP"; then
  aws logs delete-log-group --log-group-name "$LOG_GROUP"
  echo "✓ Log Group '$LOG_GROUP' 已刪除。"
else
  echo "ℹ️ Log Group '$LOG_GROUP' 不存在。"
fi

# 3. 刪除 S3 狀態 (可選)
echo ""
echo "[3/4] S3 狀態清理..."
if [ "$PURGE_STATE" = true ] && [ -n "$STATE_BUCKET" ] && [ "$STATE_BUCKET" != "null" ]; then
  echo "正在刪除 S3 狀態備份..."
  aws s3 rm "s3://$STATE_BUCKET/runtime/$BOT_NAME/home.tar.gz" 2>/dev/null && echo "✓ 已刪除 s3://$STATE_BUCKET/runtime/$BOT_NAME/home.tar.gz" || echo "ℹ️ Runtime tarball 不存在。"
  aws s3 rm "s3://$STATE_BUCKET/$BOT_NAME-home.tar.gz" 2>/dev/null && echo "✓ 已刪除舊版 key s3://$STATE_BUCKET/$BOT_NAME-home.tar.gz" || true
  aws s3 rm "s3://$STATE_BUCKET/layers/4-bot/$BOT_NAME/" --recursive 2>/dev/null && echo "✓ 已刪除 s3://$STATE_BUCKET/layers/4-bot/$BOT_NAME/" || true
  aws s3 rm "s3://$STATE_BUCKET/shared/$BOT_NAME/" --recursive 2>/dev/null && echo "✓ 已刪除舊版 shared key s3://$STATE_BUCKET/shared/$BOT_NAME/" || true
else
  echo "ℹ️ 跳過 S3 狀態清理。"
fi

# 4. 刪除 Secrets Manager (可選)
echo ""
echo "[4/4] Secrets Manager 清理..."
if [ "$PURGE_SECRET" = true ] && [ -n "$SECRET_PATH" ] && [ "$SECRET_PATH" != "null" ] && [ "$SECRET_PATH" != "''" ]; then
  REGION=$(yq eval '.region' "$ENV_FILE")
  echo "正在刪除 Secret: $SECRET_PATH..."
  aws secretsmanager delete-secret --secret-id "$SECRET_PATH" --force-delete-without-recovery --region "$REGION" 2>/dev/null && \
    echo "✓ Secret '$SECRET_PATH' 已排程刪除。" || \
    echo "⚠️ 無法刪除 Secret '$SECRET_PATH'，可能不存在或無權限。"
else
  echo "ℹ️ 跳過 Secrets Manager 清理。"
fi

echo ""
echo "==========================================="
echo "✅ Bot '$BOT_NAME' 的清理作業完成。"
echo "==========================================="
