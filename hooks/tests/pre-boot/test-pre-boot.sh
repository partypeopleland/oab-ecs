#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  local exit_code=$?

  rm -rf "$TMP_DIR"
  rm -f /tmp/awscli.zip /tmp/uv.tar.gz /tmp/uv.tar.gz.sha256
  rm -rf /tmp/aws /tmp/uv-x86_64-unknown-linux-musl
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

assert_file_exists() {
  local path=$1
  local desc=$2
  if [ -f "$path" ]; then
    echo "  ✅ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $desc"
    echo "     缺少檔案: $path"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_contains() {
  local file=$1
  local pattern=$2
  local desc=$3
  if grep -qF -- "$pattern" "$file"; then
    echo "  ✅ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $desc"
    echo "     缺少: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

make_aws_zip_fixture() {
  local fixture_dir="$1"
  local payload_dir="$fixture_dir/aws"
  mkdir -p "$payload_dir"

  cat > "$payload_dir/install" <<'EOF'
#!/bin/sh
set -e

bin_dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bin-dir)
      bin_dir=$2
      shift 2
      ;;
    --install-dir)
      shift 2
      ;;
    --update)
      shift
      ;;
    *)
      shift
      ;;
  esac
done

mkdir -p "$bin_dir"
cat > "$bin_dir/aws" <<'EOS'
#!/bin/sh
printf 'aws-stub %s\n' "$*"
EOS
chmod +x "$bin_dir/aws"
EOF
  chmod +x "$payload_dir/install"

  (cd "$fixture_dir" && zip -qr awscli.zip aws)
  printf '%s\n' "$fixture_dir/awscli.zip"
}

make_uv_tar_fixture() {
  local fixture_dir="$1"
  local payload_dir="$fixture_dir/uv-x86_64-unknown-linux-musl"
  mkdir -p "$payload_dir"

  cat > "$payload_dir/uv" <<'EOF'
#!/bin/sh
printf 'uv-stub %s\n' "$*"
EOF
  chmod +x "$payload_dir/uv"

  (cd "$fixture_dir" && tar -czf uv.tar.gz uv-x86_64-unknown-linux-musl)
  printf '%s\n' "$fixture_dir/uv.tar.gz"
}

create_curl_stub() {
  local stub_dir=$1
  local stub_path="$stub_dir/curl"

  cat > "$stub_path" <<'EOF'
#!/bin/bash
set -euo pipefail

out=""
url=""

while [ $# -gt 0 ]; do
  case "$1" in
    -o)
      out=$2
      shift 2
      ;;
    --)
      shift
      ;;
    -*)
      shift
      ;;
    http*)
      url=$1
      shift
      ;;
    *)
      shift
      ;;
  esac
done

printf '%s\n' "$url" >> "$CURL_LOG"

  case "$url" in
  *awscli-exe-linux-x86_64-2.35.7.zip)
    cp "$AWSCLI_ZIP_FIXTURE" "$out"
    ;;
  *uv-x86_64-unknown-linux-musl.tar.gz.sha256)
    cp "$UV_SHA_FIXTURE" "$out"
    ;;
  *uv-x86_64-unknown-linux-musl.tar.gz)
    cp "$UV_TAR_FIXTURE" "$out"
    ;;
  *)
    echo "unsupported curl url: $url" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$stub_path"
}

assert_not_contains() {
  local file=$1
  local pattern=$2
  local desc=$3
  if grep -qF -- "$pattern" "$file"; then
    echo "  ❌ $desc"
    echo "     不應出現: $pattern"
    FAIL=$((FAIL + 1))
  else
    echo "  ✅ $desc"
    PASS=$((PASS + 1))
  fi
}

run_case() {
  local case_dir="$TMP_DIR/case"
  mkdir -p "$case_dir/bin" "$case_dir/fixtures" "$case_dir/home"

  local aws_zip_fixture
  local uv_tar_fixture
  aws_zip_fixture="$(make_aws_zip_fixture "$case_dir/fixtures")"
  uv_tar_fixture="$(make_uv_tar_fixture "$case_dir/fixtures")"

  local uv_sha_value
  uv_sha_value="$(sha256sum "$uv_tar_fixture" | awk '{print $1}')"
  printf '%s  %s\n' "$uv_sha_value" "uv-x86_64-unknown-linux-musl.tar.gz" > "$case_dir/fixtures/uv.tar.gz.sha256"

  local curl_log="$case_dir/curl.log"

  create_curl_stub "$case_dir/bin"

  export PATH="$case_dir/bin:$PATH"
  export HOME="$case_dir/home"
  export CURL_LOG="$curl_log"
  export AWSCLI_ZIP_FIXTURE="$aws_zip_fixture"
  export UV_TAR_FIXTURE="$uv_tar_fixture"
  export UV_SHA_FIXTURE="$case_dir/fixtures/uv.tar.gz.sha256"
  export STATE_BUCKET=""
  export OPENAB_BACKEND_AGENT="backend"
  export OPENAB_AGENT_NAME="ghost"

  local pre_boot_output
  if ! pre_boot_output=$("$ROOT_DIR/hooks/pre-boot.sh" 2>&1); then
    echo "  ❌ pre-boot.sh 執行失敗"
    echo "$pre_boot_output"
    FAIL=$((FAIL + 1))
    return
  fi

  assert_file_exists "$HOME/bin/aws" "AWS CLI 已安裝"
  assert_file_exists "$HOME/bin/uv" "uv 已安裝"
  assert_file_contains "$curl_log" "awscli-exe-linux-x86_64-2.35.7.zip" "AWS CLI 使用固定版本 URL"
  assert_file_contains "$curl_log" "releases/download/0.11.21/uv-x86_64-unknown-linux-musl.tar.gz" "uv 使用固定版本 URL"
  assert_file_contains "$curl_log" "releases/download/0.11.21/uv-x86_64-unknown-linux-musl.tar.gz.sha256" "uv checksum 已下載"
  assert_not_contains "$curl_log" "latest/download" "沒有再使用 latest 下載"
}

echo "=== pre-boot.sh 測試 ==="
run_case
echo ""
echo "=========================================="
echo "測試結果: $PASS 通過, $FAIL 失敗"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
