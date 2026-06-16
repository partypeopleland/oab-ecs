#!/bin/bash
# validate.sh
# 驗證 bots.yaml 中所有 Bot 的設定是否合法，並提示解決方案。
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOTS_FILE="$SCRIPT_DIR/bots.yaml"
ENV_FILE="$SCRIPT_DIR/aws-env.yaml"

if [ ! -f "$BOTS_FILE" ]; then
  echo "錯誤: 找不到 bots.yaml 檔案。"
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "錯誤: 找不到 aws-env.yaml 檔案。請先執行 ops/aws-init.sh。"
  exit 1
fi

if ! command -v yq &>/dev/null; then
  echo "錯誤: 找不到 yq 工具。請安裝 yq (https://github.com/mikefarah/yq)"
  exit 1
fi

ERRORS=0
WARNINGS=0

# Fargate 合法的 CPU/Memory 組合
VALID_COMBOS=(
  "256:512"
  "256:1024"
  "256:2048"
  "512:1024"
  "512:2048"
  "512:3072"
  "1024:2048"
  "1024:3072"
  "1024:4096"
  "2048:4096"
  "2048:5120"
  "2048:6144"
  "2048:8192"
  "4096:8192"
  "4096:10240"
  "4096:12288"
  "4096:16384"
  "8192:16384"
  "8192:20480"
  "8192:24576"
  "16384:32768"
  "16384:49152"
  "16384:65536"
)

# 讀取全域設定
REGION=$(yq eval '.region' "$ENV_FILE")
CLUSTER=$(yq eval '.cluster' "$ENV_FILE")

echo "=== OpenAB Bot 設定驗證 ==="
echo "全域環境: cluster=$CLUSTER, region=$REGION"
echo "------------------------------------------"

# 取得所有 bot 名稱
BOTS=$(yq eval 'keys | .[]' "$BOTS_FILE")

for BOT in $BOTS; do
  echo ""
  echo "🔍 驗證 Bot: $BOT"
  BOT_ERRORS=0

  # 檢查必填欄位
  REQUIRED_FIELDS=("backend_agent" "image" "agent_command" "secret_path" "cpu" "memory" "capacity" "pre_boot_url" "pre_boot_sha256" "pre_shutdown_url" "pre_shutdown_sha256")

  for FIELD in "${REQUIRED_FIELDS[@]}"; do
    VALUE=$(yq eval ".$BOT.$FIELD" "$BOTS_FILE")
    if [ -z "$VALUE" ] || [ "$VALUE" = "null" ] || [ "$VALUE" = "''" ]; then
      echo "  ❌ 缺少必填欄位: $FIELD"
      echo "     → 請在 bots.yaml 的 $BOT 區塊下新增 $FIELD 欄位"
      BOT_ERRORS=$((BOT_ERRORS + 1))
    fi
  done

  # 驗證 CPU/Memory 組合
  CPU=$(yq eval ".$BOT.cpu" "$BOTS_FILE" | tr -d "'\"")
  MEMORY=$(yq eval ".$BOT.memory" "$BOTS_FILE" | tr -d "'\"")
  if [ -n "$CPU" ] && [ -n "$MEMORY" ] && [ "$CPU" != "null" ] && [ "$MEMORY" != "null" ]; then
    COMBO="${CPU}:${MEMORY}"
    if [[ ! " ${VALID_COMBOS[@]} " =~ " ${COMBO} " ]]; then
      echo "  ❌ 無效的 CPU/Memory 組合: CPU=$CPU, Memory=$MEMORY"
      echo "     → Fargate 合法組合: 256/512, 256/1024, 256/2048, 512/1024, 512/2048, 512/3072, 1024/2048~4096, ..."
      echo "     → 參考: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AWS_Fargate_VPU_memory.html"
      BOT_ERRORS=$((BOT_ERRORS + 1))
    fi
  fi

  # 驗證 capacity
  CAPACITY=$(yq eval ".$BOT.capacity" "$BOTS_FILE")
  if [ -n "$CAPACITY" ] && [ "$CAPACITY" != "null" ]; then
    if [ "$CAPACITY" != "FARGATE_SPOT" ] && [ "$CAPACITY" != "FARGATE" ]; then
      echo "  ❌ 無效的 capacity 值: $CAPACITY"
      echo "     → 允許的值: FARGATE_SPOT (較便宜但可能中斷) 或 FARGATE (穩定但較貴)"
      BOT_ERRORS=$((BOT_ERRORS + 1))
    fi
  fi

  # 驗證 image 格式
  IMAGE=$(yq eval ".$BOT.image" "$BOTS_FILE")
  if [ -n "$IMAGE" ] && [ "$IMAGE" != "null" ]; then
    if ! echo "$IMAGE" | grep -qE '^[a-z0-9.-]+(/[a-z0-9._-]+)*(:[a-z0-9._-]+)?$'; then
      echo "  ⚠️ Image 格式可能不正確: $IMAGE"
      echo "     → 建議格式: registry/path:tag (如 ghcr.io/openabdev/openab-antigravity:0.8.5-beta.9)"
      WARNINGS=$((WARNINGS + 1))
    fi
  fi

  # 驗證 secret_path 格式
  SECRET_PATH=$(yq eval ".$BOT.secret_path" "$BOTS_FILE")
  if [ -n "$SECRET_PATH" ] && [ "$SECRET_PATH" != "null" ] && [ "$SECRET_PATH" != "''" ]; then
    if ! echo "$SECRET_PATH" | grep -qE '^[a-zA-Z0-9/_-]+$'; then
      echo "  ❌ secret_path 格式不正確: $SECRET_PATH"
      echo "     → 只允許英數字、底線、斜線、破折號 (如 openab/oab-ghost)"
      BOT_ERRORS=$((BOT_ERRORS + 1))
    fi
  fi

  # 驗證 pre_boot/pre_shutdown url 格式
  for HOOK_URL_FIELD in "pre_boot_url" "pre_shutdown_url"; do
    HOOK_URL=$(yq eval ".$BOT.$HOOK_URL_FIELD" "$BOTS_FILE")
    if [ -n "$HOOK_URL" ] && [ "$HOOK_URL" != "null" ]; then
      if ! echo "$HOOK_URL" | grep -qE '^https://'; then
        echo "  ❌ $HOOK_URL_FIELD 必須是 HTTPS URL: $HOOK_URL"
        BOT_ERRORS=$((BOT_ERRORS + 1))
      fi
    fi
  done

  # 驗證 pre_boot/pre_shutdown sha256 格式
  for SHA_FIELD in "pre_boot_sha256" "pre_shutdown_sha256"; do
    SHA_VAL=$(yq eval ".$BOT.$SHA_FIELD" "$BOTS_FILE")
    if [ -n "$SHA_VAL" ] && [ "$SHA_VAL" != "null" ]; then
      if ! echo "$SHA_VAL" | grep -qE '^[a-f0-9]{64}$'; then
        echo "  ❌ $SHA_FIELD 必須是 64 位元十六進位字串: $SHA_VAL"
        echo "     → 可用以下指令計算: sha256sum <script_file> | awk '{print \$1}'"
        BOT_ERRORS=$((BOT_ERRORS + 1))
      fi
    fi
  done

  if [ "$BOT_ERRORS" -eq 0 ]; then
    echo "  ✅ 驗證通過"
  else
    ERRORS=$((ERRORS + BOT_ERRORS))
  fi
done

echo ""
echo "=========================================="
if [ "$ERRORS" -gt 0 ]; then
  echo "❌ 驗證完成: $ERRORS 個錯誤, $WARNINGS 個警告"
  exit 1
elif [ "$WARNINGS" -gt 0 ]; then
  echo "⚠️ 驗證完成: 0 個錯誤, $WARNINGS 個警告"
  exit 0
else
  echo "✅ 驗證完成: 所有 Bot 設定合法"
  exit 0
fi
