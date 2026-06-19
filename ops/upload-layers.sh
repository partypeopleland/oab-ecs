#!/bin/bash
# upload-layers.sh
# 同步本地的 overlay layers 2~5 至 S3 Bucket
set -e

usage() {
  cat <<'EOF'
用途:
  將本地 state/layers/2-common 到 5-agents 同步到指定 bot 使用的 S3 bucket。

使用方式:
  upload-layers.sh <bot名稱>

範例:
  ops/upload-layers.sh ghost
  ops/upload-layers.sh spirit

注意:
  會對 Layer 2-4 使用 aws s3 sync --delete。
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

# 檢查引數
if [ -z "${1:-}" ]; then
  usage
  exit 1
fi

BOT_NAME=$1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/aws-env.yaml"
BOTS_FILE="$SCRIPT_DIR/bots.yaml"

if ! command -v yq &>/dev/null; then
  echo "錯誤: 找不到 yq 工具。請安裝 yq (https://github.com/mikefarah/yq)"
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "錯誤: 找不到 aws-env.yaml 檔案。"
  exit 1
fi

if [ ! -f "$BOTS_FILE" ]; then
  echo "錯誤: 找不到 bots.yaml 檔案。"
  exit 1
fi

# 檢查 bot 是否存在於 bots.yaml 中
if [ "$(yq eval "has(\"$BOT_NAME\")" "$BOTS_FILE")" != "true" ]; then
  echo "錯誤: Bot '$BOT_NAME' 未在 bots.yaml 中定義。"
  exit 1
fi

STATE_BUCKET=$(yq eval ".\"$BOT_NAME\".state_bucket" "$BOTS_FILE")
if [ -z "$STATE_BUCKET" ] || [ "$STATE_BUCKET" = "null" ]; then
  STATE_BUCKET=$(yq eval '.state_bucket' "$ENV_FILE")
fi

if [ -z "$STATE_BUCKET" ] || [ "$STATE_BUCKET" = "null" ]; then
  echo "錯誤: 未在 bots.yaml 或 aws-env.yaml 中設定 state_bucket。"
  exit 1
fi

BACKEND_AGENT=$(yq eval ".\"$BOT_NAME\".backend_agent" "$BOTS_FILE")
if [ -z "$BACKEND_AGENT" ] || [ "$BACKEND_AGENT" = "null" ]; then
  echo "錯誤: Bot '$BOT_NAME' 缺少 backend_agent 設定。"
  exit 1
fi

echo "正在同步本地 overlay layers 至 S3 Bucket '$STATE_BUCKET'..."
if [ -d "$SCRIPT_DIR/../state/layers/2-common" ]; then
  echo "同步 Layer 2: 全域共用靜態資源..."
  aws s3 sync "$SCRIPT_DIR/../state/layers/2-common/" "s3://$STATE_BUCKET/layers/2-common/" --delete --quiet
fi

if [ -d "$SCRIPT_DIR/../state/layers/3-backend/$BACKEND_AGENT" ]; then
  echo "同步 Layer 3: backend 共用靜態資源 ($BACKEND_AGENT)..."
  aws s3 sync "$SCRIPT_DIR/../state/layers/3-backend/$BACKEND_AGENT/" "s3://$STATE_BUCKET/layers/3-backend/$BACKEND_AGENT/" --delete --quiet
fi

if [ -d "$SCRIPT_DIR/../state/layers/4-bot/$BOT_NAME" ]; then
  echo "同步 Layer 4: bot 專屬靜態資源 ($BOT_NAME)..."
  aws s3 sync "$SCRIPT_DIR/../state/layers/4-bot/$BOT_NAME/" "s3://$STATE_BUCKET/layers/4-bot/$BOT_NAME/" --delete --quiet
fi

if [ -f "$SCRIPT_DIR/../state/layers/5-agents/AGENTS.md" ]; then
  echo "同步 Layer 5: 共用 AGENTS.md..."
  aws s3 cp "$SCRIPT_DIR/../state/layers/5-agents/AGENTS.md" "s3://$STATE_BUCKET/layers/5-agents/AGENTS.md" --quiet
fi

echo "✓ S3 overlay layers 同步完成。"
