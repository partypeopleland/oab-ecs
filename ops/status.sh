#!/bin/bash
# status.sh
# 查詢特定 Bot 的 ECS 服務狀態、任務詳情與最新 CloudWatch 日誌。
set -e

usage() {
  cat <<'EOF'
用途:
  查詢指定 bot 的 ECS service 狀態、task 資訊與最近 CloudWatch 日誌。

使用方式:
  status.sh <bot名稱> [顯示行數]

範例:
  ops/status.sh ghost
  ops/status.sh spirit 100
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
LIMIT=${2:-50}
SERVICE_NAME="openab-$BOT_NAME"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/aws-env.yaml"

if [ ! -f "$ENV_FILE" ]; then
  echo "錯誤: 找不到 aws-env.yaml 檔案。請先執行 ops/aws-init.sh 產生。"
  exit 1
fi

# 使用 yq 讀取全域設定
if command -v yq &>/dev/null; then
  CLUSTER=$(yq eval '.cluster' "$ENV_FILE")
else
  CLUSTER="openab-cluster"
fi

[ -z "$CLUSTER" ] && CLUSTER="openab-cluster"

echo "=== 查詢 Bot 服務狀態: $BOT_NAME ==="
echo "AWS Cluster: $CLUSTER"
echo "ECS Service: $SERVICE_NAME"
echo "------------------------------------------"

# 1. 查詢 ECS 服務狀態 (使用 JMESPath)
echo "[1/3] 正在取得 ECS 服務設定與狀態..."
SERVICE_JSON=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE_NAME" 2>/dev/null || echo "")

STATUS=$(echo "$SERVICE_JSON" | jq -r '.services[0].status // empty' 2>/dev/null || echo "")

if [ -z "$STATUS" ]; then
  echo "❌ 找不到服務 '$SERVICE_NAME'。請確認是否已部署過該機器人。"
  exit 1
fi

DESIRED=$(echo "$SERVICE_JSON" | jq -r '.services[0].desiredCount // 0' 2>/dev/null)
RUNNING=$(echo "$SERVICE_JSON" | jq -r '.services[0].runningCount // 0' 2>/dev/null)
PENDING=$(echo "$SERVICE_JSON" | jq -r '.services[0].pendingCount // 0' 2>/dev/null)
EXEC_ENABLED=$(echo "$SERVICE_JSON" | jq -r '.services[0].enableExecuteCommand // false' 2>/dev/null)

echo "服務狀態: $STATUS"
echo "預期副本數 (Desired): $DESIRED | 運行中 (Running): $RUNNING | 啟動中 (Pending): $PENDING"
echo "遠端偵錯 (ExecuteCommand): $EXEC_ENABLED"
echo "------------------------------------------"

# 2. 查詢運行中或最近的 Task 詳情
echo "[2/3] 正在取得運行中/配置中的 Task 資訊..."
TASK_ARNS=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE_NAME" --query "taskArns" --output text)

ACTIVE_TASK_ID=""
if [ -n "$TASK_ARNS" ] && [ "$TASK_ARNS" != "None" ]; then
  FIRST_TASK_ARN=$(echo "$TASK_ARNS" | awk '{print $1}')
  ACTIVE_TASK_ID="${FIRST_TASK_ARN##*/}"
fi

if [ -z "$TASK_ARNS" ] || [ "$TASK_ARNS" = "None" ]; then
  echo "ℹ️ 目前無任何運行中或啟動中的 Task 任務。"
else
  aws ecs describe-tasks --cluster "$CLUSTER" --tasks $TASK_ARNS \
    --query "tasks[].{taskArn:taskArn,lastStatus:lastStatus,healthStatus:healthStatus,desiredStatus:desiredStatus}" \
    --output table 2>/dev/null || echo "⚠️ 無法取得 Task 詳情。"
fi
echo "------------------------------------------"

# 3. 查詢最新 CloudWatch 日誌
echo "[3/3] 正在從 CloudWatch 取得最近 $LIMIT 筆日誌..."
LOG_GROUP="/ecs/$SERVICE_NAME"

STREAM_NAME=""
if [ -n "$ACTIVE_TASK_ID" ]; then
  # 優先尋找名稱包含目前運行中 Task ID 的 log stream
  STREAM_NAME=$(aws logs describe-log-streams --log-group-name "$LOG_GROUP" --query "logStreams[?contains(logStreamName, '$ACTIVE_TASK_ID')].logStreamName" --output text 2>/dev/null || echo "")
fi

# 如果找不到（例如新容器還沒建立 Log Stream），或是目前無運行中的 Task，則 Fallback 排序 LastEventTime
if [ -z "$STREAM_NAME" ] || [ "$STREAM_NAME" = "None" ]; then
  STREAM_NAME=$(aws logs describe-log-streams --log-group-name "$LOG_GROUP" --order-by LastEventTime --descending --limit 1 --query "logStreams[0].logStreamName" --output text 2>/dev/null || echo "")
fi

if [ -z "$STREAM_NAME" ] || [ "$STREAM_NAME" = "None" ]; then
  echo "⚠️ 找不到日誌群組 '$LOG_GROUP' 或尚無任何日誌流事件。"
else
  echo "最新日誌流: $STREAM_NAME"
  echo "--- 日誌輸出開始 ---"

  # 取得最近 $LIMIT 筆事件，並將毫秒時間戳轉為可讀格式
  aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$STREAM_NAME" --limit "$LIMIT" \
    --query "events[*].{time:timestamp,message:message}" --output json 2>/dev/null \
    | jq -r '.[] | "\((.time/1000) | todate) | \(.message)"' 2>/dev/null || \
  aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$STREAM_NAME" --limit "$LIMIT" \
    --query "events[*].message" --output text

  echo "--- 日誌輸出結束 ---"
fi
echo "=========================================="
