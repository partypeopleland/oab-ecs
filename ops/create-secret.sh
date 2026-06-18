#!/bin/bash
set -euo pipefail

build_secret_string() {
  local token=$1
  jq -cn --arg token "$token" '{DISCORD_BOT_TOKEN:$token}'
}

main() {
  # 檢查參數
  if [ "$#" -ne 2 ]; then
    echo "使用方法: $0 <bot名稱> <DISCORD_BOT_TOKEN>"
    echo "例如: $0 spirit MTIzNDU2Nzg5..."
    exit 1
  fi

  if ! command -v aws >/dev/null 2>&1; then
    echo "錯誤: 找不到 aws CLI。"
    exit 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "錯誤: 找不到 jq 工具。請安裝 jq (https://stedolan.github.io/jq/download/)"
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
  if [ -f "$ENV_FILE" ] && command -v yq >/dev/null 2>&1; then
    REGION=$(yq eval '.region' "$ENV_FILE")
  fi

  secret_string="$(build_secret_string "$BOT_TOKEN")"

  echo "正在建立 AWS Secret: $SECRET_NAME ..."

  aws_args=(
    aws secretsmanager create-secret
    --name "$SECRET_NAME"
    --description "OpenAB Bot Configuration Secrets for $BOT_NAME"
    --secret-string "$secret_string"
  )

  if [ -n "$REGION" ] && [ "$REGION" != "null" ]; then
    aws_args+=(--region "$REGION")
  fi

  "${aws_args[@]}"

  echo "✓ 成功建立密鑰: $SECRET_NAME"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
