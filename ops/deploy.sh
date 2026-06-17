#!/bin/bash
set -e

# 檢查引數
if [ -z "$1" ]; then
  echo "使用方法: $0 <bot名稱> [apply|render]"
  echo "例如: $0 ghost"
  exit 1
fi

BOT_NAME=$1
ACTION=${2:-apply}

# 定義檔案路徑
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOTS_FILE="$SCRIPT_DIR/bots.yaml"
ENV_FILE="$SCRIPT_DIR/aws-env.yaml"
TEMPLATE_FILE="$SCRIPT_DIR/openab-ecs.yaml.template"
TEMP_FILE="$SCRIPT_DIR/.deploy-$BOT_NAME.yaml"

# 檢查 yq 是否可用
if ! command -v yq &>/dev/null; then
  echo "錯誤: 找不到 yq 工具。請安裝 yq (https://github.com/mikefarah/yq)"
  exit 1
fi

# 檢查必要檔案是否存在
if [ ! -f "$BOTS_FILE" ]; then
  echo "錯誤: 找不到 bots.yaml 檔案。"
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "錯誤: 找不到 aws-env.yaml 檔案。請先執行 ops/aws-init.sh 自動探測並產生環境檔。"
  exit 1
fi

if [ ! -f "$TEMPLATE_FILE" ]; then
  echo "錯誤: 找不到 openab-ecs.yaml.template 模板檔案。"
  exit 1
fi

# 檢查 bot 是否存在於 bots.yaml 中
if ! yq eval "has(\"$BOT_NAME\")" "$BOTS_FILE" | grep -q "true"; then
  echo "錯誤: Bot '$BOT_NAME' 未在 bots.yaml 中定義。"
  echo "可用的 Bot 清單:"
  yq eval 'keys | .[]' "$BOTS_FILE"
  exit 1
fi

# 1. 讀取全域設定 (從 aws-env.yaml)
CLUSTER=$(yq eval '.cluster' "$ENV_FILE")
EXECUTION_ROLE_ARN=$(yq eval '.execution_role_arn' "$ENV_FILE")
TASK_ROLE_ARN=$(yq eval '.task_role_arn' "$ENV_FILE")
STATE_BUCKET_GLOBAL=$(yq eval '.state_bucket' "$ENV_FILE")
REGION=$(yq eval '.region' "$ENV_FILE")
SUBNETS=$(yq eval '.subnets' "$ENV_FILE" | sed 's/^/    /')
SECURITY_GROUPS=$(yq eval '.security_groups' "$ENV_FILE" | sed 's/^/    /')

# 2. 讀取 Bot 各項專屬參數 (從 bots.yaml)
BACKEND_AGENT=$(yq eval ".$BOT_NAME.backend_agent" "$BOTS_FILE")
IMAGE=$(yq eval ".$BOT_NAME.image" "$BOTS_FILE")
AGENT_COMMAND=$(yq eval ".$BOT_NAME.agent_command" "$BOTS_FILE")
SECRET_PATH=$(yq eval ".$BOT_NAME.secret_path" "$BOTS_FILE")
CPU=$(yq eval ".$BOT_NAME.cpu" "$BOTS_FILE")
MEMORY=$(yq eval ".$BOT_NAME.memory" "$BOTS_FILE")
CAPACITY=$(yq eval ".$BOT_NAME.capacity" "$BOTS_FILE")
STATE_BUCKET=$(yq eval ".$BOT_NAME.state_bucket" "$BOTS_FILE")

# state_bucket: bot 專屬 > 全域
if [ -z "$STATE_BUCKET" ] || [ "$STATE_BUCKET" = "null" ] || [ "$STATE_BUCKET" = "''" ]; then
  STATE_BUCKET="$STATE_BUCKET_GLOBAL"
fi

PRE_BOOT_URL=$(yq eval ".$BOT_NAME.pre_boot_url" "$BOTS_FILE")
PRE_BOOT_SHA256=$(yq eval ".$BOT_NAME.pre_boot_sha256" "$BOTS_FILE")
PRE_SHUTDOWN_URL=$(yq eval ".$BOT_NAME.pre_shutdown_url" "$BOTS_FILE")
PRE_SHUTDOWN_SHA256=$(yq eval ".$BOT_NAME.pre_shutdown_sha256" "$BOTS_FILE")

# 複製模板檔案為臨時部署檔
cp "$TEMPLATE_FILE" "$TEMP_FILE"

# 替換模板中的預留位置 (使用 @ 作為分隔符，避免路徑中的 / 造成衝突)
sed -i "s@{{name}}@$BOT_NAME@g" "$TEMP_FILE"
sed -i "s@{{backend_agent}}@$BACKEND_AGENT@g" "$TEMP_FILE"
sed -i "s@{{image}}@$IMAGE@g" "$TEMP_FILE"
sed -i "s@{{agent_command}}@$AGENT_COMMAND@g" "$TEMP_FILE"
sed -i "s@{{secret_path}}@$SECRET_PATH@g" "$TEMP_FILE"
sed -i "s@{{cpu}}@$CPU@g" "$TEMP_FILE"
sed -i "s@{{memory}}@$MEMORY@g" "$TEMP_FILE"
sed -i "s@{{capacity}}@$CAPACITY@g" "$TEMP_FILE"
sed -i "s@{{state_bucket}}@$STATE_BUCKET@g" "$TEMP_FILE"
sed -i "s@{{region}}@$REGION@g" "$TEMP_FILE"
# 加上時間戳以破除 Gist CDN 快取
PRE_BOOT_URL_FRESH="$PRE_BOOT_URL"
if [[ "$PRE_BOOT_URL" == *"gist.githubusercontent.com"* ]]; then
  PRE_BOOT_URL_FRESH="${PRE_BOOT_URL}?t=$(date +%s)"
fi

PRE_SHUTDOWN_URL_FRESH="$PRE_SHUTDOWN_URL"
if [[ "$PRE_SHUTDOWN_URL" == *"gist.githubusercontent.com"* ]]; then
  PRE_SHUTDOWN_URL_FRESH="${PRE_SHUTDOWN_URL}?t=$(date +%s)"
fi

sed -i "s@{{pre_boot_url}}@$PRE_BOOT_URL_FRESH@g" "$TEMP_FILE"
sed -i "s@{{pre_boot_sha256}}@$PRE_BOOT_SHA256@g" "$TEMP_FILE"
sed -i "s@{{pre_shutdown_url}}@$PRE_SHUTDOWN_URL_FRESH@g" "$TEMP_FILE"
sed -i "s@{{pre_shutdown_sha256}}@$PRE_SHUTDOWN_SHA256@g" "$TEMP_FILE"
sed -i "s@{{cluster}}@$CLUSTER@g" "$TEMP_FILE"
sed -i "s@{{execution_role_arn}}@$EXECUTION_ROLE_ARN@g" "$TEMP_FILE"
sed -i "s@{{task_role_arn}}@$TASK_ROLE_ARN@g" "$TEMP_FILE"

# 替換多行變數 (使用 awk 避免 newline 造成 sed 語法錯誤)
awk -v r="$SUBNETS" '{gsub(/{{subnets}}/, r)}1' "$TEMP_FILE" > "$TEMP_FILE.tmp" && mv "$TEMP_FILE.tmp" "$TEMP_FILE"
awk -v r="$SECURITY_GROUPS" '{gsub(/{{security_groups}}/, r)}1' "$TEMP_FILE" > "$TEMP_FILE.tmp" && mv "$TEMP_FILE.tmp" "$TEMP_FILE"

echo "✓ 已成功渲染部署設定檔至: $TEMP_FILE"

# 如果 ACTION 是 render，則只渲染，不進行部署
if [ "$ACTION" = "render" ]; then
  echo "操作設定為 'render'。已跳過部署步驟。"
  exit 0
fi

# 確保 CloudWatch Log Group 存在 (不存在時自動建立)
LOG_GROUP="/ecs/openab-$BOT_NAME"
echo "檢查 CloudWatch Log Group '$LOG_GROUP'..."
if ! aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --query "logGroups[?logGroupName=='$LOG_GROUP'].logGroupName" --output text | grep -q "$LOG_GROUP"; then
  echo "⚠️ 找不到 Log Group '$LOG_GROUP'。正在建立..."
  aws logs create-log-group --log-group-name "$LOG_GROUP"
  echo "✓ Log Group '$LOG_GROUP' 建立成功。"
else
  echo "✓ Log Group '$LOG_GROUP' 已經存在。"
fi

# 執行 ecsctl 部署
echo "執行部署指令: ecsctl apply -f $TEMP_FILE"
if ecsctl apply -f "$TEMP_FILE"; then
  echo "✓ 部署成功！"
  rm -f "$TEMP_FILE"
else
  echo "錯誤: ecsctl apply 執行失敗。"
  rm -f "$TEMP_FILE"
  exit 1
fi
