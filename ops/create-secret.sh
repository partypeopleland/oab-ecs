#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
用途:
  建立 secret 或更新既有 secret 的單一欄位。

使用方法:
  舊模式:
    create-secret.sh <bot名稱> <DISCORD_BOT_TOKEN>

  通用模式:
    create-secret.sh <secret名稱> <KEY> <VALUE>

範例:
  create-secret.sh spirit MTIzNDU2Nzg5...
  create-secret.sh openab/oab-spirit GH_TOKEN ghp_xxx
  create-secret.sh openab/oab-spirit GROQ_APIKEY gsk_xxx
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

read_region() {
  local script_dir=$1
  local env_file="$script_dir/aws-env.yaml"
  local region=""

  if [ -f "$env_file" ] && command -v yq >/dev/null 2>&1; then
    region=$(yq eval '.region' "$env_file")
  fi

  printf '%s' "$region"
}

aws_sm() {
  local args=(aws secretsmanager "$@")
  if [ -n "${REGION:-}" ] && [ "$REGION" != "null" ]; then
    args+=(--region "$REGION")
  fi
  "${args[@]}"
}

secret_exists() {
  aws_sm describe-secret --secret-id "$1" >/dev/null 2>&1
}

read_existing_secret_string() {
  aws_sm get-secret-value --secret-id "$1" --query SecretString --output text 2>/dev/null || true
}

build_merged_secret_string() {
  local existing_json=$1
  local key=$2
  local value=$3

  if [ -z "$existing_json" ] || [ "$existing_json" = "None" ] || [ "$existing_json" = "null" ]; then
    jq -cn --arg key "$key" --arg value "$value" '{($key): $value}'
    return
  fi

  if ! printf '%s' "$existing_json" | jq empty >/dev/null 2>&1; then
    echo "錯誤: 現有 SecretString 不是合法 JSON，無法安全合併。" >&2
    exit 1
  fi

  printf '%s' "$existing_json" \
    | jq -c --arg key "$key" --arg value "$value" '. + {($key): $value}'
}

create_or_update_secret() {
  local secret_name=$1
  local key=$2
  local value=$3
  local description=${4:-"OpenAB Bot Configuration Secrets"}
  local existing_secret_string=""
  local merged_secret_string=""

  if secret_exists "$secret_name"; then
    existing_secret_string="$(read_existing_secret_string "$secret_name")"
    merged_secret_string="$(build_merged_secret_string "$existing_secret_string" "$key" "$value")"
    echo "正在更新 AWS Secret: $secret_name ..."
    aws_sm put-secret-value \
      --secret-id "$secret_name" \
      --secret-string "$merged_secret_string" >/dev/null
    echo "✓ 成功更新密鑰: $secret_name (欄位: $key)"
  else
    merged_secret_string="$(build_merged_secret_string "" "$key" "$value")"
    echo "正在建立 AWS Secret: $secret_name ..."
    aws_sm create-secret \
      --name "$secret_name" \
      --description "$description" \
      --secret-string "$merged_secret_string" >/dev/null
    echo "✓ 成功建立密鑰: $secret_name (欄位: $key)"
  fi
}

main() {
  local secret_name=""
  local key=""
  local value=""
  local description=""
  local script_dir=""

  if ! command -v aws >/dev/null 2>&1; then
    echo "錯誤: 找不到 aws CLI。"
    exit 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "錯誤: 找不到 jq 工具。請安裝 jq (https://stedolan.github.io/jq/download/)"
    exit 1
  fi

  if [ "$#" -ne 2 ] && [ "$#" -ne 3 ]; then
    usage
    exit 1
  fi

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REGION="$(read_region "$script_dir")"

  if [ "$#" -eq 2 ]; then
    local bot_name=$1
    secret_name="openab/oab-$bot_name"
    key="DISCORD_BOT_TOKEN"
    value=$2
    description="OpenAB Bot Configuration Secrets for $bot_name"
  else
    secret_name=$1
    key=$2
    value=$3
    description="OpenAB Secret $secret_name"
  fi

  create_or_update_secret "$secret_name" "$key" "$value" "$description"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
