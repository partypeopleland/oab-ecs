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
  local existing_secret_mode=$4
  shift 4
  local cli_args=("$@")

  local case_dir="$TMP_DIR/$case_name"
  mkdir -p "$case_dir/bin"

  local aws_log="$case_dir/aws.log"
  local aws_calls_log="$case_dir/aws-calls.log"
  local yq_log="$case_dir/yq.log"
  local aws_stub="$case_dir/bin/aws"
  local yq_stub="$case_dir/bin/yq"

  cat > "$aws_stub" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$AWS_LOG"
printf '%s\n' "$*" >> "$AWS_CALLS_LOG"

if [ "${1:-}" = "secretsmanager" ] && [ "${2:-}" = "describe-secret" ]; then
  case "${AWS_SECRET_EXISTS_MODE:-missing}" in
    exists) exit 0 ;;
    missing) exit 255 ;;
  esac
fi

if [ "${1:-}" = "secretsmanager" ] && [ "${2:-}" = "get-secret-value" ]; then
  printf '%s' "${AWS_EXISTING_SECRET_STRING:-}"
  exit 0
fi
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
  export AWS_CALLS_LOG="$aws_calls_log"
  export YQ_LOG="$yq_log"
  export YQ_OUTPUT="$case_dir/region.txt"
  export AWS_SECRET_EXISTS_MODE="$existing_secret_mode"
  export AWS_EXISTING_SECRET_STRING=""

  printf '%s\n' "$expected_region" > "$YQ_OUTPUT"

  local env_file="$ROOT_DIR/ops/aws-env.yaml"
  if [ "$env_file_mode" = "with-env" ]; then
    cp "$SCRIPT_DIR/fixtures/aws-env.test.yaml" "$env_file"
  else
    rm -f "$env_file"
  fi

  if [ "$existing_secret_mode" = "exists" ]; then
    export AWS_EXISTING_SECRET_STRING='{"DISCORD_BOT_TOKEN":"old-token","OTHER_KEY":"keep-me"}'
  fi

  if ! "$ROOT_DIR/ops/create-secret.sh" "${cli_args[@]}" >/dev/null 2>&1; then
    echo "  ❌ $case_name 執行失敗"
    FAIL=$((FAIL + 1))
  else
    local secret_json
    local expected_json
    local action
    action="$(awk 'NR==2 { print; exit }' "$aws_log")"
    secret_json="$(awk 'prev=="--secret-string" { print; exit } { prev=$0 }' "$aws_log")"
    local region_flag_present
    region_flag_present="$(grep -n '^--region$' "$aws_log" || true)"

    case "$case_name" in
      with-region-legacy-create)
        expected_json="$(jq -cn --arg token 'tok"en\with spaces' '{DISCORD_BOT_TOKEN:$token}')"
        assert_eq "$action" "create-secret" "$case_name 使用 create-secret"
        ;;
      without-region-legacy-create)
        expected_json="$(jq -cn --arg token 'simple-token' '{DISCORD_BOT_TOKEN:$token}')"
        assert_eq "$action" "create-secret" "$case_name 使用 create-secret"
        ;;
      explicit-update-merge)
        expected_json="$(jq -cn --arg token 'old-token' --arg other 'keep-me' --arg gh 'ghp_new_token' '{DISCORD_BOT_TOKEN:$token,OTHER_KEY:$other,GH_TOKEN:$gh}')"
        assert_eq "$action" "put-secret-value" "$case_name 使用 put-secret-value"
        ;;
      explicit-create-custom-key)
        expected_json="$(jq -cn --arg groq 'gsk_live_xxx' '{GROQ_APIKEY:$groq}')"
        assert_eq "$action" "create-secret" "$case_name 使用 create-secret"
        ;;
      *)
        echo "  ❌ 未知測試案例: $case_name"
        FAIL=$((FAIL + 1))
        expected_json=""
        ;;
    esac

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

run_case "with-region-legacy-create" "with-env" "us-west-2" "missing" ghost 'tok"en\with spaces'
run_case "without-region-legacy-create" "no-env" "__no_region__" "missing" ghost "simple-token"
run_case "explicit-update-merge" "with-env" "us-west-2" "exists" openab/oab-ghost GH_TOKEN "ghp_new_token"
run_case "explicit-create-custom-key" "with-env" "us-west-2" "missing" openab/oab-spirit GROQ_APIKEY "gsk_live_xxx"

echo ""
echo "=========================================="
echo "測試結果: $PASS 通過, $FAIL 失敗"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
