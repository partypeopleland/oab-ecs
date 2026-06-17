#!/bin/bash
set -e

# 檢查引數
if [ -z "$1" ]; then
  echo "使用方法: $0 <bot名稱>"
  echo "例如: $0 ghost"
  exit 1
fi

BOT_NAME=$1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/aws-env.yaml"
BOTS_FILE="$SCRIPT_DIR/bots.yaml"

if [ ! -f "$ENV_FILE" ]; then
  echo "錯誤: 找不到 aws-env.yaml 檔案。"
  exit 1
fi

if [ ! -f "$BOTS_FILE" ]; then
  echo "錯誤: 找不到 bots.yaml 檔案。"
  exit 1
fi

# 檢查 bot 是否存在於 bots.yaml 中
if ! grep -q "^$BOT_NAME:" "$BOTS_FILE"; then
  echo "錯誤: Bot '$BOT_NAME' 未在 bots.yaml 中定義。"
  exit 1
fi

# 讀取特定 Bot 的 state_bucket 設定 (優先從 bots.yaml，其次從 aws-env.yaml)
get_val() {
  local key=$1
  sed -n "/^$BOT_NAME:/,/^[a-zA-Z]/p" "$BOTS_FILE" \
    | grep -w "$key" \
    | head -n 1 \
    | sed -E "s/[[:space:]]*$key:[[:space:]]*//; s/^[\"']//; s/[\"']$//"
}

get_global_val() {
  local key=$1
  grep -w "$key" "$ENV_FILE" \
    | head -n 1 \
    | sed -E "s/[[:space:]]*$key:[[:space:]]*//; s/^[\"']//; s/[\"']$//"
}

STATE_BUCKET=$(get_val "state_bucket")
if [ -z "$STATE_BUCKET" ]; then
  STATE_BUCKET=$(get_global_val "state_bucket")
fi

if [ -z "$STATE_BUCKET" ]; then
  echo "錯誤: 未在 bots.yaml 或 aws-env.yaml 中設定 state_bucket。"
  exit 1
fi

echo "正在同步本地 state 目錄至 S3 Bucket '$STATE_BUCKET'..."
if [ -d "$SCRIPT_DIR/../state/shared" ]; then
  echo "同步共享資源..."
  aws s3 sync "$SCRIPT_DIR/../state/shared/" "s3://$STATE_BUCKET/shared/" --delete --quiet
fi

if [ -d "$SCRIPT_DIR/../state/$BOT_NAME" ]; then
  echo "打包並上傳 '$BOT_NAME' 專屬環境..."
  tar -czf "/tmp/$BOT_NAME-home.tar.gz" -C "$SCRIPT_DIR/../state/$BOT_NAME" .
  aws s3 cp "/tmp/$BOT_NAME-home.tar.gz" "s3://$STATE_BUCKET/$BOT_NAME-home.tar.gz" --quiet
  rm -f "/tmp/$BOT_NAME-home.tar.gz"
fi
echo "✓ S3 狀態同步完成。"
