#!/bin/bash
# check-layers.sh
# 直接從 CloudWatch 取得特定 Bot 的 pre-boot 日誌並檢查 Layer 1~5 同步狀況。
set -euo pipefail

usage() {
  cat <<'EOF'
用途:
  從 CloudWatch 日誌檢查指定 bot 的 pre-boot 是否成功載入 Layer 1-5。

使用方式:
  check-layers.sh <bot名稱>

範例:
  ops/check-layers.sh ghost
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

BOT_NAME="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/aws-env.yaml"
SERVICE_NAME="openab-$BOT_NAME"
LOG_GROUP="/ecs/$SERVICE_NAME"

# 1. 檢查依賴工具與讀取 Cluster 設定
if ! command -v jq &>/dev/null; then
  echo "錯誤: 找不到必要工具 'jq'"
  exit 1
fi

CLUSTER="openab-cluster"
if [ -f "$ENV_FILE" ]; then
  if command -v yq &>/dev/null; then
    CLUSTER=$(yq eval '.cluster' "$ENV_FILE")
  fi
fi

# 2. 取得目前運行中的 Task ID
TASK_ARNS=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE_NAME" --query "taskArns" --output text 2>/dev/null || echo "")

ACTIVE_TASK_ID=""
if [ -n "$TASK_ARNS" ] && [ "$TASK_ARNS" != "None" ] && [ "$TASK_ARNS" != "" ]; then
  FIRST_TASK_ARN=$(echo "$TASK_ARNS" | awk '{print $1}')
  ACTIVE_TASK_ID="${FIRST_TASK_ARN##*/}"
fi

# 3. 尋找對應的 Log Stream
STREAM_NAME=""
if [ -n "$ACTIVE_TASK_ID" ]; then
  STREAM_NAME=$(aws logs describe-log-streams --log-group-name "$LOG_GROUP" --query "logStreams[?contains(logStreamName, '$ACTIVE_TASK_ID')].logStreamName" --output text 2>/dev/null || echo "")
fi

# 如果找不到（新容器尚未寫日誌，或無運行中 Task），Fallback 至最新的 Log Stream
if [ -z "$STREAM_NAME" ] || [ "$STREAM_NAME" = "None" ] || [ "$STREAM_NAME" = "" ]; then
  STREAM_NAME=$(aws logs describe-log-streams --log-group-name "$LOG_GROUP" --order-by LastEventTime --descending --limit 1 --query "logStreams[0].logStreamName" --output text 2>/dev/null || echo "")
fi

if [ -z "$STREAM_NAME" ] || [ "$STREAM_NAME" = "None" ] || [ "$STREAM_NAME" = "" ]; then
  echo "❌ 找不到服務 '$SERVICE_NAME' 的日誌流，請確認是否已部署過。"
  exit 1
fi

echo "正在從 Log Stream 讀取 pre-boot 記錄: $STREAM_NAME"
# 讀取最近 200 筆事件 (使用 jq 確保換行，並清除 ANSI 轉義碼)
LOG_CONTENT=$(aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$STREAM_NAME" --limit 200 --output json 2>/dev/null | jq -r '.events[].message' | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' || echo "")

if [ -z "$LOG_CONTENT" ]; then
  echo "⚠️ 日誌內容為空。"
  exit 1
fi

echo "=== $BOT_NAME Layer 同步檢查結果 ==="

check_layer() {
  local layer_num="$1"
  local pattern="$2"
  local desc="$3"
  
  # 使用 grep -E 進行不區分大小寫的正則比對
  if echo "$LOG_CONTENT" | grep -E -qi "$pattern"; then
    echo "🟢 Layer $layer_num ($desc): 已同步成功"
    echo "$LOG_CONTENT" | grep -E -i "$pattern" | sed 's/^/   /'
  else
    echo "⚪ Layer $layer_num ($desc): 未偵測到同步事件 (若 S3 對應目錄無檔案則屬正常)"
  fi
}

# 1. Layer 1 (Runtime Home Snapshot)
check_layer 1 "download: s3://.*/(runtime/$BOT_NAME/home.tar.gz|$BOT_NAME-home.tar.gz)" "Runtime Home Snapshot"

# 2. Layer 2 (Global Common)
check_layer 2 "download: s3://.*/layers/2-common/" "Global Common Assets"

# 3. Layer 3 (Backend-specific)
check_layer 3 "download: s3://.*/layers/3-backend/" "Backend Shared Assets"

# 4. Layer 4 (Bot-specific)
check_layer 4 "download: s3://.*/layers/4-bot/$BOT_NAME/" "Bot-specific Static Assets"

# 5. Layer 5 (Shared AGENTS.md)
check_layer 5 "download: s3://.*/layers/5-agents/AGENTS.md" "Shared AGENTS.md Rules"

echo "------------------------------------------"
if echo "$LOG_CONTENT" | grep -q "hook completed successfully hook=\"pre_boot\""; then
  echo "✅ pre_boot hook 執行成功！"
else
  echo "❌ pre_boot hook 未成功完成或日誌不完整。"
fi
echo "=========================================="
