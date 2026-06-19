#!/bin/bash
# test-deploy.sh
# 測試 deploy.sh 的 yq 解析與模板渲染是否正確。
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OPS_DIR="$ROOT_DIR/ops"
BOTS_FILE="$OPS_DIR/bots.yaml"
ENV_FILE="$OPS_DIR/aws-env.yaml"
TMP_DIR="$(mktemp -d)"
ORIGINAL_BOTS_BACKUP="$TMP_DIR/original-bots.yaml"
ORIGINAL_ENV_BACKUP="$TMP_DIR/original-aws-env.yaml"
BOTS_WAS_PRESENT=0
ENV_WAS_PRESENT=0
PASS=0
FAIL=0

cleanup() {
  local exit_code=$?

  if [ "$BOTS_WAS_PRESENT" -eq 1 ] && [ -f "$ORIGINAL_BOTS_BACKUP" ]; then
    mv -f "$ORIGINAL_BOTS_BACKUP" "$BOTS_FILE"
  else
    rm -f "$BOTS_FILE"
  fi

  if [ "$ENV_WAS_PRESENT" -eq 1 ] && [ -f "$ORIGINAL_ENV_BACKUP" ]; then
    mv -f "$ORIGINAL_ENV_BACKUP" "$ENV_FILE"
  else
    rm -f "$ENV_FILE"
  fi

  rm -f "$OPS_DIR/.deploy-ghost.yaml"
  rm -rf "$TMP_DIR"
  exit "$exit_code"
}

trap cleanup EXIT INT TERM HUP

assert_contains() {
  local file=$1 pattern=$2 desc=$3
  if grep -q "$pattern" "$file"; then
    echo "  ✅ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $desc (未找到: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local file=$1 pattern=$2 desc=$3
  if grep -q "$pattern" "$file"; then
    echo "  ❌ $desc (不應存在: $pattern)"
    FAIL=$((FAIL + 1))
  else
    echo "  ✅ $desc"
    PASS=$((PASS + 1))
  fi
}

prepare_repo_fixtures() {
  if [ -f "$BOTS_FILE" ]; then
    BOTS_WAS_PRESENT=1
    cp "$BOTS_FILE" "$ORIGINAL_BOTS_BACKUP"
  fi

  if [ -f "$ENV_FILE" ]; then
    ENV_WAS_PRESENT=1
    cp "$ENV_FILE" "$ORIGINAL_ENV_BACKUP"
  fi

  cp "$SCRIPT_DIR/fixtures/bots.test.yaml" "$BOTS_FILE"
  cp "$SCRIPT_DIR/fixtures/aws-env.test.yaml" "$ENV_FILE"
}

echo "=== Deploy.sh 測試 ==="
echo ""
prepare_repo_fixtures

# --- Test 1: yq 讀取 bots.yaml ---
echo "Test 1: yq 讀取 bots.yaml"
BOT_COUNT=$(yq eval 'keys | length' "$BOTS_FILE")
if [ "$BOT_COUNT" -gt 0 ]; then
  echo "  ✅ 找到 $BOT_COUNT 個 Bot 定義"
  PASS=$((PASS + 1))
else
  echo "  ❌ bots.yaml 中無 Bot 定義"
  FAIL=$((FAIL + 1))
fi

# --- Test 2: yq 讀取 aws-env.yaml ---
echo "Test 2: yq 讀取 aws-env.yaml"
CLUSTER=$(yq eval '.cluster' "$ENV_FILE")
REGION=$(yq eval '.region' "$ENV_FILE")
if [ -n "$CLUSTER" ] && [ "$CLUSTER" != "null" ]; then
  echo "  ✅ cluster=$CLUSTER"
  PASS=$((PASS + 1))
else
  echo "  ❌ cluster 為空或 null"
  FAIL=$((FAIL + 1))
fi

if [ -n "$REGION" ] && [ "$REGION" != "null" ]; then
  echo "  ✅ region=$REGION"
  PASS=$((PASS + 1))
else
  echo "  ❌ region 為空或 null"
  FAIL=$((FAIL + 1))
fi

# --- Test 3: yq 讀取多行 subnets ---
echo "Test 3: yq 讀取多行 subnets"
SUBNETS=$(yq eval '.subnets' "$ENV_FILE")
if echo "$SUBNETS" | grep -q "subnet-"; then
  echo "  ✅ subnets 包含有效 subnet ID"
  PASS=$((PASS + 1))
else
  echo "  ❌ subnets 未包含有效 subnet ID"
  FAIL=$((FAIL + 1))
fi

# --- Test 4: render ghost 並驗證輸出 ---
echo "Test 4: render ghost"
"$OPS_DIR/deploy.sh" ghost render 2>/dev/null
RENDER_FILE="$OPS_DIR/.deploy-ghost.yaml"

if [ -f "$RENDER_FILE" ]; then
  echo "  ✅ 渲染檔案已產生"
  PASS=$((PASS + 1))

  # 驗證所有 placeholder 已被替換
  assert_not_contains "$RENDER_FILE" '{{name}}' 'placeholder {{name}} 已替換'
  assert_not_contains "$RENDER_FILE" '{{backend_agent}}' 'placeholder {{backend_agent}} 已替換'
  assert_not_contains "$RENDER_FILE" '{{image}}' 'placeholder {{image}} 已替換'
  assert_not_contains "$RENDER_FILE" '{{agent_command}}' 'placeholder {{agent_command}} 已替換'
  assert_not_contains "$RENDER_FILE" '{{secret_path}}' 'placeholder {{secret_path}} 已替換'
  assert_not_contains "$RENDER_FILE" '{{cpu}}' 'placeholder {{cpu}} 已替換'
  assert_not_contains "$RENDER_FILE" '{{memory}}' 'placeholder {{memory}} 已替換'
  assert_not_contains "$RENDER_FILE" '{{capacity}}' 'placeholder {{capacity}} 已替換'
  assert_not_contains "$RENDER_FILE" '{{state_bucket}}' 'placeholder {{state_bucket}} 已替換'
  assert_not_contains "$RENDER_FILE" '{{region}}' 'placeholder {{region}} 已替換'
  assert_not_contains "$RENDER_FILE" '{{cluster}}' 'placeholder {{cluster}} 已替換'
  assert_not_contains "$RENDER_FILE" '{{execution_role_arn}}' 'placeholder {{execution_role_arn}} 已替換'
  assert_not_contains "$RENDER_FILE" '{{task_role_arn}}' 'placeholder {{task_role_arn}} 已替換'
  assert_not_contains "$RENDER_FILE" '{{pre_boot_url}}' 'placeholder {{pre_boot_url}} 已替換'
  assert_not_contains "$RENDER_FILE" '{{pre_boot_sha256}}' 'placeholder {{pre_boot_sha256}} 已替換'
  assert_not_contains "$RENDER_FILE" '{{pre_shutdown_url}}' 'placeholder {{pre_shutdown_url}} 已替換'
  assert_not_contains "$RENDER_FILE" '{{pre_shutdown_sha256}}' 'placeholder {{pre_shutdown_sha256}} 已替換'

  # 驗證內容正確
  assert_contains "$RENDER_FILE" "name: openab-ghost" 'Service name 正確'
  assert_contains "$RENDER_FILE" "cluster: $CLUSTER" 'Cluster 正確'
  assert_contains "$RENDER_FILE" "capacity: FARGATE_SPOT" 'Capacity 正確'
  assert_contains "$RENDER_FILE" "AWS_REGION: $REGION" 'Region 正確'
  assert_contains "$RENDER_FILE" "OPENAB_AGENT_COMMAND: agy-acp" 'Agent command 環境變數正確'
  assert_contains "$RENDER_FILE" "OPENAB_AGENT_NAME: ghost" 'Agent name 環境變數正確'

  # 清理
  rm -f "$RENDER_FILE"
else
  echo "  ❌ 渲染檔案未產生"
  FAIL=$((FAIL + 1))
fi

# --- Test 5: validate.sh 通過 ---
echo "Test 5: validate.sh"
if "$OPS_DIR/validate.sh" >/dev/null 2>&1; then
  echo "  ✅ validate.sh 通過"
  PASS=$((PASS + 1))
else
  echo "  ❌ validate.sh 失敗"
  FAIL=$((FAIL + 1))
fi

# --- Test 6: 測試不存在的 bot ---
echo "Test 6: 測試不存在的 bot"
if "$OPS_DIR/deploy.sh" nonexistent_bot render 2>&1 | grep -q "未在 bots.yaml 中定義"; then
  echo "  ✅ 正確拒絕不存在的 bot"
  PASS=$((PASS + 1))
else
  echo "  ❌ 未正確拒絕不存在的 bot"
  FAIL=$((FAIL + 1))
fi

# --- Summary ---
echo ""
echo "=========================================="
echo "測試結果: $PASS 通過, $FAIL 失敗"
if [ "$FAIL" -gt 0 ]; then
  echo "❌ 有測試失敗！"
  exit 1
else
  echo "✅ 所有測試通過！"
  exit 0
fi
