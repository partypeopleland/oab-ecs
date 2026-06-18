#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
ORIGINAL_BOTS_BACKUP="$TMP_DIR/original-bots.yaml"
ORIGINAL_ENV_BACKUP="$TMP_DIR/original-aws-env.yaml"
ORIGINAL_AGENTS_BACKUP="$TMP_DIR/original-AGENTS.md"
BOT_LIST=("ghost" "spirit")

cleanup() {
  local exit_code=$?

  if [ -f "$ORIGINAL_BOTS_BACKUP" ]; then
    mv -f "$ORIGINAL_BOTS_BACKUP" "$ROOT_DIR/ops/bots.yaml"
  fi

  if [ -f "$ORIGINAL_ENV_BACKUP" ]; then
    mv -f "$ORIGINAL_ENV_BACKUP" "$ROOT_DIR/ops/aws-env.yaml"
  else
    rm -f "$ROOT_DIR/ops/aws-env.yaml"
  fi

  if [ -f "$ORIGINAL_AGENTS_BACKUP" ]; then
    mkdir -p "$ROOT_DIR/state/layers/5-agents"
    mv -f "$ORIGINAL_AGENTS_BACKUP" "$ROOT_DIR/state/layers/5-agents/AGENTS.md"
  fi

  for bot in "${BOT_LIST[@]}"; do
    rm -rf "$ROOT_DIR/state/layers/2-common/.state-bucket-test"
    rm -rf "$ROOT_DIR/state/layers/3-backend/.state-bucket-test"
    rm -rf "$ROOT_DIR/state/layers/4-bot/$bot/.state-bucket-test"
    rm -rf "$ROOT_DIR/restored/$bot"
  done
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

assert_file_contains() {
  local file=$1
  local pattern=$2
  local desc=$3
  if grep -qF "$pattern" "$file"; then
    echo "  ✅ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $desc"
    echo "     缺少: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

prepare_repo_fixtures() {
  cp "$SCRIPT_DIR/fixtures/bots.test.yaml" "$ROOT_DIR/ops/bots.yaml"
  cp "$SCRIPT_DIR/fixtures/aws-env.test.yaml" "$ROOT_DIR/ops/aws-env.yaml"

  mkdir -p \
    "$ROOT_DIR/state/layers/2-common" \
    "$ROOT_DIR/state/layers/3-backend/agy" \
    "$ROOT_DIR/state/layers/3-backend/kiro" \
    "$ROOT_DIR/state/layers/4-bot/ghost" \
    "$ROOT_DIR/state/layers/4-bot/spirit" \
    "$ROOT_DIR/state/layers/5-agents" \
    "$ROOT_DIR/restored"
}

create_yq_stub() {
  local stub_dir=$1
  local stub_path="$stub_dir/yq"

  cat > "$stub_path" <<'EOF'
#!/bin/bash
set -euo pipefail

mode=${1:-}
expr=${2:-}
file=${3:-}

read_block_field() {
  local target=$1
  local field=$2
  local file_path=$3
  awk -v target="$target" -v field="$field" '
    $0 ~ "^" target ":" { in_block=1; next }
    in_block && /^[^[:space:]]/ { exit }
    in_block && $1 == field ":" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      print $0
      exit
    }
  ' "$file_path"
}

normalize_optional_value() {
  local raw_value=$1
  case "$raw_value" in
    "''"|"\"\""|"")
      printf '\n'
      ;;
    *)
      printf '%s\n' "$raw_value"
      ;;
  esac
}

read_global_state_bucket() {
  local raw_value
  raw_value=$(
    awk '
      $1 == "state_bucket:" {
        sub(/^[[:space:]]*state_bucket:[[:space:]]*/, "", $0)
        print $0
        exit
      }
    ' "$file"
  )
  normalize_optional_value "$raw_value"
}

case "$mode" in
  eval)
    case "$expr" in
      'has("ghost")')
        grep -q '^ghost:' "$file" && echo true || echo false
        ;;
      'has("spirit")')
        grep -q '^spirit:' "$file" && echo true || echo false
        ;;
      '."ghost".state_bucket')
        normalize_optional_value "$(read_block_field ghost state_bucket "$file")"
        ;;
      '."spirit".state_bucket')
        normalize_optional_value "$(read_block_field spirit state_bucket "$file")"
        ;;
      '."ghost".backend_agent')
        read_block_field ghost backend_agent "$file"
        ;;
      '."spirit".backend_agent')
        read_block_field spirit backend_agent "$file"
        ;;
      '.state_bucket')
        read_global_state_bucket
        ;;
      *)
        echo "unsupported yq expression: $expr" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "unsupported yq mode: $mode" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$stub_path"
}

create_aws_stub() {
  local stub_dir=$1
  local stub_path="$stub_dir/aws"

  cat > "$stub_path" <<'EOF'
#!/bin/bash
set -euo pipefail

printf 'CALL %s\n' "$*" >> "$AWS_LOG"

if [ "$1" = "s3" ] && [ "$2" = "cp" ]; then
  if [[ "$4" != s3://* ]]; then
    cp "$AWS_TAR_SOURCE" "$4"
  fi
fi
EOF
  chmod +x "$stub_path"
}

run_case() {
  local case_name=$1
  local bot_name=$2
  local backend_agent=$3
  local expected_bucket=$4
  local layer2_marker_dir="$ROOT_DIR/state/layers/2-common/.state-bucket-test"
  local layer3_marker_dir="$ROOT_DIR/state/layers/3-backend/$backend_agent/.state-bucket-test"
  local layer4_marker_dir="$ROOT_DIR/state/layers/4-bot/$bot_name/.state-bucket-test"
  local layer5_file="$ROOT_DIR/state/layers/5-agents/AGENTS.md"
  local case_dir="$TMP_DIR/$case_name"
  mkdir -p "$case_dir/bin" "$case_dir/restore-src"
  mkdir -p "$layer2_marker_dir" "$layer3_marker_dir" "$layer4_marker_dir"

  local aws_log="$case_dir/aws.log"
  local restore_tar="$case_dir/home.tar.gz"

  printf 'layer2-%s\n' "$case_name" > "$layer2_marker_dir/$case_name"
  printf 'layer3-%s\n' "$case_name" > "$layer3_marker_dir/$case_name"
  printf 'layer4-%s\n' "$case_name" > "$layer4_marker_dir/$case_name"
  printf 'layer5-%s\n' "$case_name" > "$layer5_file"
  printf 'restored-%s\n' "$case_name" > "$case_dir/restore-src/config.txt"

  tar -czf "$restore_tar" -C "$case_dir/restore-src" .

  create_aws_stub "$case_dir/bin"
  create_yq_stub "$case_dir/bin"

  export PATH="$case_dir/bin:$PATH"
  export AWS_LOG="$aws_log"
  export AWS_TAR_SOURCE="$restore_tar"

  local save_output
  if ! save_output=$("$ROOT_DIR/ops/upload-layers.sh" "$bot_name" 2>&1); then
    echo "  ❌ $case_name upload-layers.sh 執行失敗"
    echo "$save_output"
    FAIL=$((FAIL + 1))
    return
  fi

  assert_file_contains "$aws_log" "s3://$expected_bucket/layers/2-common/" "$case_name layer2 bucket 正確"
  assert_file_contains "$aws_log" "s3://$expected_bucket/layers/3-backend/$backend_agent/" "$case_name layer3 bucket 正確"
  assert_file_contains "$aws_log" "s3://$expected_bucket/layers/4-bot/$bot_name/" "$case_name layer4 bucket 正確"
  assert_file_contains "$aws_log" "s3://$expected_bucket/layers/5-agents/AGENTS.md" "$case_name layer5 bucket 正確"

  local restore_output
  if ! restore_output=$("$ROOT_DIR/ops/restore-layer1.sh" "$bot_name" 2>&1); then
    echo "  ❌ $case_name restore-layer1.sh 執行失敗"
    echo "$restore_output"
    FAIL=$((FAIL + 1))
    return
  fi

  assert_file_contains "$aws_log" "s3://$expected_bucket/runtime/$bot_name/home.tar.gz" "$case_name restore runtime key 正確"
  assert_eq "$(cat "$ROOT_DIR/restored/$bot_name/config.txt")" "restored-$case_name" "$case_name restore 內容正確"
}

if [ -f "$ROOT_DIR/ops/bots.yaml" ]; then
  cp "$ROOT_DIR/ops/bots.yaml" "$ORIGINAL_BOTS_BACKUP"
fi

if [ -f "$ROOT_DIR/ops/aws-env.yaml" ]; then
  cp "$ROOT_DIR/ops/aws-env.yaml" "$ORIGINAL_ENV_BACKUP"
fi

if [ -f "$ROOT_DIR/state/layers/5-agents/AGENTS.md" ]; then
  cp "$ROOT_DIR/state/layers/5-agents/AGENTS.md" "$ORIGINAL_AGENTS_BACKUP"
fi

prepare_repo_fixtures

echo "=== state bucket scripts 測試 ==="
echo ""

run_case "bot-override" "ghost" "agy" "ghost-specific-bucket"
run_case "global-fallback" "spirit" "kiro" "global-state-bucket"

echo ""
echo "=========================================="
echo "測試結果: $PASS 通過, $FAIL 失敗"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
