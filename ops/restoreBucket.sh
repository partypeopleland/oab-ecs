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

RESTORE_DIR="$SCRIPT_DIR/../restored/$BOT_NAME"
echo "正在從 S3 Bucket '$STATE_BUCKET' 下載並還原 '$BOT_NAME' 狀態至本地 '$RESTORE_DIR'..."

# 下載並解壓 Bot 的專屬狀態到新路徑下
TEMP_TAR="/tmp/$BOT_NAME-home-download.tar.gz"

if aws s3 cp "s3://$STATE_BUCKET/$BOT_NAME-home.tar.gz" "$TEMP_TAR" --quiet; then
  echo "建立並清空新目錄: $RESTORE_DIR"
  rm -rf "$RESTORE_DIR"
  mkdir -p "$RESTORE_DIR"
  
  echo "解壓縮檔案中..."
  tar -xzf "$TEMP_TAR" -C "$RESTORE_DIR"
  rm -f "$TEMP_TAR"
  echo "✓ 檔案成功複製回: $RESTORE_DIR"
else
  echo "錯誤: 無法從 S3 下載 s3://$STATE_BUCKET/$BOT_NAME-home.tar.gz，或檔案不存在。"
  exit 1
fi
