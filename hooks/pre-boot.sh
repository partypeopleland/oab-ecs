#!/bin/sh
set -e

# Env vars expected: OPENAB_BACKEND_AGENT, OPENAB_AGENT_NAME, STATE_BUCKET
HOME="${HOME:-/home/agent}"
export HOME
export AWS_PAGER=""

# Download and install AWS CLI from official source
echo "從官方下載 AWS CLI..."
curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscli.zip
unzip -qo /tmp/awscli.zip -d /tmp
/tmp/aws/install --bin-dir "$HOME/bin" --install-dir "$HOME/aws-cli" --update
rm -rf /tmp/awscli.zip /tmp/aws
export PATH="$HOME/bin:$PATH"
AWS_BIN="$HOME/bin/aws"

# Try S3 cache first for uv, upload cache if missing
UV_CACHE_KEY="cache/uv-x86_64-unknown-linux-musl.tar.gz"
if [ -n "$STATE_BUCKET" ] && "$AWS_BIN" --no-cli-pager s3 cp "s3://$STATE_BUCKET/$UV_CACHE_KEY" /tmp/uv.tar.gz --quiet 2>/dev/null; then
  echo "✓ 從 S3 快取載入 uv"
else
  echo "⚠️ S3 快取不存在，從官方下載 uv 並快取至 S3..."
  curl -sSL "https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-musl.tar.gz" -o /tmp/uv.tar.gz
  if [ -n "$STATE_BUCKET" ]; then
    "$AWS_BIN" --no-cli-pager s3 cp /tmp/uv.tar.gz "s3://$STATE_BUCKET/$UV_CACHE_KEY" --quiet || true
  fi
fi
tar -xzf /tmp/uv.tar.gz -C /tmp
mv /tmp/uv-x86_64-unknown-linux-musl/uv "$HOME/bin/uv"
chmod +x "$HOME/bin/uv"
rm -rf /tmp/uv.tar.gz /tmp/uv-x86_64-unknown-linux-musl

# Layer 1: Restore agent home from tarball (preserves permissions/symlinks)
if [ -n "$STATE_BUCKET" ] && "$AWS_BIN" --no-cli-pager s3 cp "s3://$STATE_BUCKET/$OPENAB_AGENT_NAME-home.tar.gz" /tmp/home.tar.gz --quiet 2>/dev/null; then
  tar xzf /tmp/home.tar.gz -C "$HOME"
  rm -f /tmp/home.tar.gz
fi

# Layer 2.1: Overlay global shared assets (all agents common)
if [ -n "$STATE_BUCKET" ]; then
  "$AWS_BIN" --no-cli-pager s3 sync "s3://$STATE_BUCKET/shared/common/" "$HOME/" || true
fi

# Layer 2.2: Overlay shared backend assets (skills, config per backend type)
if [ -n "$STATE_BUCKET" ] && [ -n "$OPENAB_BACKEND_AGENT" ]; then
  "$AWS_BIN" --no-cli-pager s3 sync "s3://$STATE_BUCKET/shared/$OPENAB_BACKEND_AGENT/" "$HOME/" || true
fi

# Layer 3: Overlay shared AGENTS.md (always wins)
if [ -n "$STATE_BUCKET" ]; then
  "$AWS_BIN" --no-cli-pager s3 cp "s3://$STATE_BUCKET/shared/AGENTS.md" "$HOME/" || true
fi

# ghp: gh CLI shim that routes reads through ghpool
chmod +x "$HOME/bin/"* 2>/dev/null || true
chmod +x "$HOME/bin/ghp" 2>/dev/null || true
ln -sf "$HOME/bin/ghp" "$HOME/bin/gh" 2>/dev/null || true

# Shared helper scripts restored from S3 may lose executable bits.
chmod +x "$HOME/.openab/"*.sh 2>/dev/null || true
