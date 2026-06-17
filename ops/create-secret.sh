#!/bin/bash
set -e

# 檢查參數
if [ "$#" -ne 2 ]; then
  echo "使用方法: $0 <bot名稱> <DISCORD_BOT_TOKEN>"
  echo "例如: $0 spirit MTIzNDU2Nzg5..."
  exit 1
fi

BOT_NAME=$1
BOT_TOKEN=$2
SECRET_NAME="openab/oab-$BOT_NAME"

# 取得腳本目錄與環境變數檔
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/aws-env.yaml"
REGION=""

# 嘗試從 aws-env.yaml 讀取 region
if [ -f "$ENV_FILE" ] && command -v yq &>/dev/null; then
  REGION=$(yq eval '.region' "$ENV_FILE")
fi

REGION_FLAG=""
if [ -n "$REGION" ] && [ "$REGION" != "null" ]; then
  REGION_FLAG="--region $REGION"
fi

echo "正在建立 AWS Secret: $SECRET_NAME ..."

aws secretsmanager create-secret \
  --name "$SECRET_NAME" \
  --description "OpenAB Bot Configuration Secrets for $BOT_NAME" \
  --secret-string "{\"DISCORD_BOT_TOKEN\":\"$BOT_TOKEN\"}" \
  $REGION_FLAG

echo "✓ 成功建立密鑰: $SECRET_NAME"
