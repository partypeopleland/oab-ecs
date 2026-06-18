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
if [ -z "$STATE_BUCKET" ] || [ "$STATE_BUCKET" = "null" ] || [ "$STATE_BUCKET" = "''" ]; then
  STATE_BUCKET=$(yq eval '.state_bucket' "$ENV_FILE")
fi

if [ -z "$STATE_BUCKET" ] || [ "$STATE_BUCKET" = "null" ] || [ "$STATE_BUCKET" = "''" ]; then
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
