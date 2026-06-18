#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
ORIGINAL_AWS_INIT_BACKUP="$TMP_DIR/original-aws-init.yaml"
ORIGINAL_AWS_ENV_BACKUP="$TMP_DIR/original-aws-env.yaml"

cleanup() {
  local exit_code=$?

  if [ -f "$ORIGINAL_AWS_INIT_BACKUP" ]; then
    mv -f "$ORIGINAL_AWS_INIT_BACKUP" "$ROOT_DIR/ops/aws-init.yaml"
  fi

  if [ -f "$ORIGINAL_AWS_ENV_BACKUP" ]; then
    mv -f "$ORIGINAL_AWS_ENV_BACKUP" "$ROOT_DIR/ops/aws-env.yaml"
  else
    rm -f "$ROOT_DIR/ops/aws-env.yaml"
  fi

  rm -rf "$TMP_DIR"
  rm -f /tmp/awscli.zip /tmp/awscli.zip.sig /tmp/uv.tar.gz /tmp/uv.tar.gz.sha256
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

assert_contains() {
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

make_awscli_fixture() {
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
set -e

printf 'CALL %s\n' "$*" >> "$AWS_LOG"

case "$AWS_CASE" in
  auto)
    case "$*" in
      *"sts get-caller-identity --query"*)
        case "$4" in
          Arn)
            echo "arn:aws:sts::123456789012:assumed-role/openab-test-role/openab-test"
            ;;
          Account)
            echo "123456789012"
            ;;
        esac
        ;;
      *"configure get region"*)
        echo "${AWS_REGION:-us-west-2}"
        ;;
      *"ecs create-cluster"*)
        ;;
      *"ecs describe-clusters"*)
        echo "MISSING"
        ;;
      *"iam get-role"*)
        exit 1
        ;;
      *"iam create-role"*)
        role_name=""
        prev=""
        for arg in "$@"; do
          if [ "$prev" = "--role-name" ]; then
            role_name="$arg"
          fi
          prev="$arg"
        done
        echo "arn:aws:iam::123456789012:role/${role_name:-openab-role}"
        ;;
      *"iam attach-role-policy"*)
        ;;
      *"iam put-role-policy"*)
        ;;
      *"ec2 describe-security-groups"*)
        echo "None"
        ;;
      *"ec2 describe-vpcs"*)
        echo "vpc-auto-123"
        ;;
      *"ec2 create-security-group"*)
        echo "sg-auto-123"
        ;;
      *"ec2 describe-subnets"*)
        printf 'subnet-auto-a\tsubnet-auto-b\tsubnet-auto-c\n'
        ;;
      *"s3api head-bucket"*)
        exit 1
        ;;
      *"s3api create-bucket"*)
        ;;
      *"s3api head-object"*)
        exit 1
        ;;
      *"s3 cp"*)
        ;;
      *)
        echo "unsupported aws call: $*" >&2
        exit 1
        ;;
    esac
    ;;
  override)
    case "$*" in
      *"sts get-caller-identity --query"*)
        case "$4" in
          Arn)
            echo "arn:aws:sts::123456789012:assumed-role/openab-test-role/openab-test"
            ;;
          Account)
            echo "123456789012"
            ;;
        esac
        ;;
      *"configure get region"*)
        echo "${AWS_REGION:-us-west-2}"
        ;;
      *"ecs create-cluster"*)
        ;;
      *"ecs describe-clusters"*)
        echo "MISSING"
        ;;
      *"iam get-role"*)
        exit 1
        ;;
      *"iam create-role"*)
        role_name=""
        prev=""
        for arg in "$@"; do
          if [ "$prev" = "--role-name" ]; then
            role_name="$arg"
          fi
          prev="$arg"
        done
        echo "arn:aws:iam::123456789012:role/${role_name:-openab-role}"
        ;;
      *"iam attach-role-policy"*)
        ;;
      *"iam put-role-policy"*)
        ;;
      *"ec2 describe-security-groups"*)
        echo "None"
        ;;
      *"ec2 describe-vpcs"*)
        echo "unexpected describe-vpcs" >&2
        exit 1
        ;;
      *"ec2 create-security-group"*)
        echo "sg-override-123"
        ;;
      *"ec2 describe-subnets"*)
        echo "unexpected describe-subnets" >&2
        exit 1
        ;;
      *"s3api head-bucket"*)
        exit 1
        ;;
      *"s3api create-bucket"*)
        ;;
      *"s3api head-object"*)
        exit 1
        ;;
      *"s3 cp"*)
        ;;
      *)
        echo "unsupported aws call: $*" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "unknown AWS_CASE: $AWS_CASE" >&2
    exit 1
    ;;
esac
EOS
chmod +x "$bin_dir/aws"
EOF
  chmod +x "$payload_dir/install"

  (cd "$fixture_dir" && zip -qr awscli.zip aws)
  printf '%s\n' "$fixture_dir/awscli.zip"
}

create_curl_stub() {
  local stub_dir=$1
  local stub_path="$stub_dir/curl"

  cat > "$stub_path" <<'EOF'
#!/bin/sh
set -e

out=""
url=""

while [ $# -gt 0 ]; do
  case "$1" in
    -o)
      out=$2
      shift 2
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
  cp "$AWSCLI_ZIP_FIXTURE" "$out"
EOF
  chmod +x "$stub_path"
}

create_aws_stub() {
  local stub_dir=$1
  local stub_path="$stub_dir/aws"

  cat > "$stub_path" <<'EOF'
#!/bin/sh
set -e

printf 'CALL %s\n' "$*" >> "$AWS_LOG"

if [ "$AWS_CASE" = "auto" ]; then
  if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ] && [ "$3" = "--query" ]; then
    case "$4" in
      Arn)
        echo "arn:aws:sts::123456789012:assumed-role/openab-test-role/openab-test"
        ;;
      Account)
        echo "123456789012"
        ;;
    esac
  elif [ "$1" = "configure" ] && [ "$2" = "get" ] && [ "$3" = "region" ]; then
    echo "${AWS_REGION:-us-west-2}"
  elif [ "$1" = "ecs" ] && [ "$2" = "describe-clusters" ]; then
    echo "MISSING"
  elif [ "$1" = "ecs" ] && [ "$2" = "create-cluster" ]; then
    :
  elif [ "$1" = "iam" ] && [ "$2" = "get-role" ]; then
    exit 1
  elif [ "$1" = "iam" ] && [ "$2" = "create-role" ]; then
    role_name=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--role-name" ]; then
        role_name="$arg"
      fi
      prev="$arg"
    done
    echo "arn:aws:iam::123456789012:role/${role_name:-openab-role}"
  elif [ "$1" = "iam" ] && [ "$2" = "attach-role-policy" ]; then
    :
  elif [ "$1" = "iam" ] && [ "$2" = "put-role-policy" ]; then
    :
  elif [ "$1" = "ec2" ] && [ "$2" = "describe-security-groups" ]; then
    echo "None"
  elif [ "$1" = "ec2" ] && [ "$2" = "describe-vpcs" ]; then
    echo "vpc-auto-123"
  elif [ "$1" = "ec2" ] && [ "$2" = "create-security-group" ]; then
    echo "sg-auto-123"
  elif [ "$1" = "ec2" ] && [ "$2" = "describe-subnets" ]; then
    printf 'subnet-auto-a\tsubnet-auto-b\tsubnet-auto-c\n'
  elif [ "$1" = "s3api" ] && [ "$2" = "head-bucket" ]; then
    exit 1
  elif [ "$1" = "s3api" ] && [ "$2" = "create-bucket" ]; then
    :
  elif [ "$1" = "s3api" ] && [ "$2" = "head-object" ]; then
    exit 1
  elif [ "$1" = "s3" ] && [ "$2" = "cp" ]; then
    :
  else
    echo "unsupported aws call: $*" >&2
    exit 1
  fi
elif [ "$AWS_CASE" = "override" ]; then
  if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ] && [ "$3" = "--query" ]; then
    case "$4" in
      Arn)
        echo "arn:aws:sts::123456789012:assumed-role/openab-test-role/openab-test"
        ;;
      Account)
        echo "123456789012"
        ;;
    esac
  elif [ "$1" = "configure" ] && [ "$2" = "get" ] && [ "$3" = "region" ]; then
    echo "${AWS_REGION:-us-west-2}"
  elif [ "$1" = "ecs" ] && [ "$2" = "describe-clusters" ]; then
    echo "MISSING"
  elif [ "$1" = "ecs" ] && [ "$2" = "create-cluster" ]; then
    :
  elif [ "$1" = "iam" ] && [ "$2" = "get-role" ]; then
    exit 1
  elif [ "$1" = "iam" ] && [ "$2" = "create-role" ]; then
    role_name=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--role-name" ]; then
        role_name="$arg"
      fi
      prev="$arg"
    done
    echo "arn:aws:iam::123456789012:role/${role_name:-openab-role}"
  elif [ "$1" = "iam" ] && [ "$2" = "attach-role-policy" ]; then
    :
  elif [ "$1" = "iam" ] && [ "$2" = "put-role-policy" ]; then
    :
  elif [ "$1" = "ec2" ] && [ "$2" = "describe-security-groups" ]; then
    echo "None"
  elif [ "$1" = "ec2" ] && [ "$2" = "describe-vpcs" ]; then
    echo "unexpected describe-vpcs" >&2
    exit 1
  elif [ "$1" = "ec2" ] && [ "$2" = "create-security-group" ]; then
    echo "sg-override-123"
  elif [ "$1" = "ec2" ] && [ "$2" = "describe-subnets" ]; then
    echo "unexpected describe-subnets" >&2
    exit 1
  elif [ "$1" = "s3api" ] && [ "$2" = "head-bucket" ]; then
    exit 1
  elif [ "$1" = "s3api" ] && [ "$2" = "create-bucket" ]; then
    :
  elif [ "$1" = "s3api" ] && [ "$2" = "head-object" ]; then
    exit 1
  elif [ "$1" = "s3" ] && [ "$2" = "cp" ]; then
    :
  else
    echo "unsupported aws call: $*" >&2
    exit 1
  fi
else
  echo "unknown AWS_CASE: $AWS_CASE" >&2
  exit 1
fi
EOF
  chmod +x "$stub_path"
}

run_case() {
  local case_name=$1
  local aws_init_fixture=$2
  local expected_vpc=$3
  local expected_subnet_a=$4
  local expected_subnet_b=$5
  local expect_describe_vpcs=$6
  local expect_describe_subnets=$7

  local case_dir="$TMP_DIR/$case_name"
  mkdir -p "$case_dir/bin" "$case_dir/fixtures"

  local awscli_zip_fixture
  awscli_zip_fixture="$(make_awscli_fixture "$case_dir/fixtures")"

  local curl_log="$case_dir/curl.log"
  local aws_log="$case_dir/aws.log"

  create_aws_stub "$case_dir/bin"
  create_curl_stub "$case_dir/bin"

  export PATH="$case_dir/bin:$PATH"
  export CURL_LOG="$curl_log"
  export AWS_LOG="$aws_log"
  export AWS_CASE="$case_name"
  export AWS_REGION="us-west-2"
  export AWSCLI_ZIP_FIXTURE="$awscli_zip_fixture"

  if [ "$aws_init_fixture" != "$ROOT_DIR/ops/aws-init.yaml" ]; then
    cp "$aws_init_fixture" "$ROOT_DIR/ops/aws-init.yaml"
  fi
  rm -f "$ROOT_DIR/ops/aws-env.yaml"

  local aws_init_output
  if ! aws_init_output=$("$ROOT_DIR/ops/aws-init.sh" 2>&1); then
    echo "  ❌ $case_name aws-init.sh 執行失敗"
    echo "$aws_init_output"
    FAIL=$((FAIL + 1))
    return
  fi

  local env_file="$ROOT_DIR/ops/aws-env.yaml"
  assert_contains "$aws_log" "sts get-caller-identity" "$case_name: 有做 AWS 身分檢查"
  assert_contains "$aws_log" "s3 cp /tmp/awscli-cache.zip" "$case_name: 有做 AWS CLI 快取上傳"
  assert_contains "$env_file" "state_bucket: openab-state-bucket-123456789012" "$case_name: state bucket 正確"
  assert_contains "$env_file" "region: us-west-2" "$case_name: region 正確"
  assert_contains "$env_file" "  - $expected_subnet_a" "$case_name: subnet A 正確"
  assert_contains "$env_file" "  - $expected_subnet_b" "$case_name: subnet B 正確"

  if [ -n "$expected_vpc" ]; then
    assert_contains "$aws_log" "create-security-group --group-name openab-sg --description Security group for OpenAB --vpc-id $expected_vpc" "$case_name: security group 使用指定 VPC"
  fi

  if [ "$expect_describe_vpcs" = "yes" ]; then
    assert_contains "$aws_log" "ec2 describe-vpcs" "$case_name: 有走自動探測 VPC"
  else
    assert_not_contains "$aws_log" "ec2 describe-vpcs" "$case_name: 沒有走自動探測 VPC"
  fi

  if [ "$expect_describe_subnets" = "yes" ]; then
    assert_contains "$aws_log" "ec2 describe-subnets --filters Name=vpc-id,Values=$expected_vpc" "$case_name: 有走自動探測 subnet"
  else
    assert_not_contains "$aws_log" "ec2 describe-subnets --filters Name=vpc-id" "$case_name: 沒有走自動探測 subnet"
  fi
}

if [ -f "$ROOT_DIR/ops/aws-init.yaml" ]; then
  cp "$ROOT_DIR/ops/aws-init.yaml" "$ORIGINAL_AWS_INIT_BACKUP"
fi

if [ -f "$ROOT_DIR/ops/aws-env.yaml" ]; then
  cp "$ROOT_DIR/ops/aws-env.yaml" "$ORIGINAL_AWS_ENV_BACKUP"
fi

echo "=== aws-init.sh 測試 ==="
run_case "auto" "$ROOT_DIR/ops/aws-init.yaml" "vpc-auto-123" "subnet-auto-a" "subnet-auto-b" "yes" "yes"
run_case "override" "$SCRIPT_DIR/fixtures/aws-init.override.test.yaml" "vpc-explicit-123" "subnet-explicit-a" "subnet-explicit-b" "no" "no"
echo ""
echo "=========================================="
echo "測試結果: $PASS 通過, $FAIL 失敗"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
