#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
ORIGINAL_ENV_BACKUP="$TMP_DIR/original-aws-env.yaml"
ENV_WAS_PRESENT=0

cleanup() {
  local exit_code=$?

  if [ "$ENV_WAS_PRESENT" -eq 1 ] && [ -f "$ORIGINAL_ENV_BACKUP" ]; then
    mv -f "$ORIGINAL_ENV_BACKUP" "$ROOT_DIR/ops/aws-env.yaml"
  else
    rm -f "$ROOT_DIR/ops/aws-env.yaml"
  fi

  rm -rf "$TMP_DIR"
  exit "$exit_code"
}

trap cleanup EXIT INT TERM HUP

PASS=0
FAIL=0

assert_eq() {
  local actual=$1
  local expected=$2
  local desc=$3
  if [ "$actual" = "$expected" ]; then
    echo "  ✅ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $desc"
    echo "     預期: $expected"
    echo "     實際: $actual"
    FAIL=$((FAIL + 1))
  fi
}

run_case() {
  local case_name=$1
  local env_file_mode=$2
  local expected_region=$3
  local token_value=$4

  local case_dir="$TMP_DIR/$case_name"
  mkdir -p "$case_dir/bin"

  local aws_log="$case_dir/aws.log"
  local yq_log="$case_dir/yq.log"
  local aws_stub="$case_dir/bin/aws"
  local yq_stub="$case_dir/bin/yq"

  cat > "$aws_stub" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$AWS_LOG"
EOF
  chmod +x "$aws_stub"

  cat > "$yq_stub" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$YQ_LOG"
cat "$YQ_OUTPUT"
EOF
  chmod +x "$yq_stub"

  export PATH="$case_dir/bin:$PATH"
  export AWS_LOG="$aws_log"
  export YQ_LOG="$yq_log"
  export YQ_OUTPUT="$case_dir/region.txt"

  printf '%s\n' "$expected_region" > "$YQ_OUTPUT"

  local env_file="$ROOT_DIR/ops/aws-env.yaml"
  if [ "$env_file_mode" = "with-env" ]; then
    cp "$SCRIPT_DIR/fixtures/aws-env.test.yaml" "$env_file"
  else
    rm -f "$env_file"
  fi

  if ! "$ROOT_DIR/ops/create-secret.sh" ghost "$token_value" >/dev/null 2>&1; then
    echo "  ❌ $case_name 執行失敗"
    FAIL=$((FAIL + 1))
  else
    local secret_json
    local expected_json
    expected_json="$(jq -cn --arg token "$token_value" '{DISCORD_BOT_TOKEN:$token}')"
    secret_json="$(awk 'prev=="--secret-string" { print; exit } { prev=$0 }' "$aws_log")"
    local region_flag_present
    region_flag_present="$(grep -n '^--region$' "$aws_log" || true)"

    assert_eq "$secret_json" "$expected_json" "$case_name secret-string 正確"
    if [ "$expected_region" != "__no_region__" ]; then
      if [ -n "$region_flag_present" ]; then
        echo "  ✅ $case_name region 參數存在"
        PASS=$((PASS + 1))
      else
        echo "  ❌ $case_name 缺少 region 參數"
        FAIL=$((FAIL + 1))
      fi
      assert_eq "$(tail -n 1 "$aws_log")" "$expected_region" "$case_name region 值正確"
    else
      if [ -n "$region_flag_present" ]; then
        echo "  ❌ $case_name 不應包含 region"
        FAIL=$((FAIL + 1))
      else
        echo "  ✅ $case_name 不包含 region"
        PASS=$((PASS + 1))
      fi
    fi
  fi
}

# 備份最原始的環境變數檔案
if [ -f "$ROOT_DIR/ops/aws-env.yaml" ]; then
  ENV_WAS_PRESENT=1
  cp "$ROOT_DIR/ops/aws-env.yaml" "$ORIGINAL_ENV_BACKUP"
fi

echo "=== create-secret.sh 測試 ==="

run_case "with-region" "with-env" "us-west-2" 'tok"en\with spaces'
run_case "without-region" "no-env" "__no_region__" "simple-token"

echo ""
echo "=========================================="
echo "測試結果: $PASS 通過, $FAIL 失敗"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
