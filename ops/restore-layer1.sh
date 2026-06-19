#!/bin/bash
# restore-layer1.sh
# 從 S3 下載與還原 Layer 1 (Runtime Home Snapshot) 至本地新路徑
set -e

usage() {
  cat <<'EOF'
用途:
  從 S3 下載指定 bot 的 Layer 1 runtime snapshot，還原到本地 restored/<bot>/。

使用方式:
  restore-layer1.sh <bot名稱>

範例:
  ops/restore-layer1.sh ghost
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

RESTORE_DIR="$SCRIPT_DIR/../restored/$BOT_NAME"
echo "正在從 S3 Bucket '$STATE_BUCKET' 下載並還原 '$BOT_NAME' 狀態至本地 '$RESTORE_DIR'..."

# 下載並解壓 Bot 的 runtime 狀態到新路徑下
TEMP_TAR="/tmp/$BOT_NAME-home-download.tar.gz"
RUNTIME_KEY="runtime/$BOT_NAME/home.tar.gz"
LEGACY_RUNTIME_KEY="$BOT_NAME-home.tar.gz"

if aws s3 cp "s3://$STATE_BUCKET/$RUNTIME_KEY" "$TEMP_TAR" --quiet || aws s3 cp "s3://$STATE_BUCKET/$LEGACY_RUNTIME_KEY" "$TEMP_TAR" --quiet; then
  echo "建立並清空新目錄: $RESTORE_DIR"
  rm -rf "$RESTORE_DIR"
  mkdir -p "$RESTORE_DIR"
  
  echo "解壓縮檔案中..."
  tar -xzf "$TEMP_TAR" -C "$RESTORE_DIR"
  rm -f "$TEMP_TAR"
  echo "✓ 檔案成功複製回: $RESTORE_DIR"
else
  echo "錯誤: 無法從 S3 下載 s3://$STATE_BUCKET/$RUNTIME_KEY（或舊版 key s3://$STATE_BUCKET/$LEGACY_RUNTIME_KEY），或檔案不存在。"
  exit 1
fi
