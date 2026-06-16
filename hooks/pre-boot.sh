#!/bin/sh
set -e

# Env vars expected: OPENAB_BACKEND_AGENT, OPENAB_AGENT_NAME, STATE_BUCKET

# Try S3 cache first (uploaded by aws-init.sh), fall back to direct download
AWSCLI_CACHE_KEY="cache/awscli-linux-x86_64.zip"
if [ -n "$STATE_BUCKET" ] && aws s3 cp "s3://$STATE_BUCKET/$AWSCLI_CACHE_KEY" /tmp/awscli.zip --quiet 2>/dev/null; then
  echo "✓ 從 S3 快取載入 AWS CLI"
else
  echo "⚠️ S3 快取不存在，從官方下載 AWS CLI..."
  curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscli.zip
fi
unzip -qo /tmp/awscli.zip -d /tmp
/tmp/aws/install --bin-dir "$HOME/bin" --install-dir "$HOME/aws-cli" --update
rm -rf /tmp/awscli.zip /tmp/aws
export PATH="$HOME/bin:$PATH"

# Layer 1: Restore agent home from tarball (preserves permissions/symlinks)
if aws s3 cp "s3://$STATE_BUCKET/$OPENAB_AGENT_NAME-home.tar.gz" /tmp/home.tar.gz --quiet 2>/dev/null; then
  tar xzf /tmp/home.tar.gz -C "$HOME"
  rm -f /tmp/home.tar.gz
fi

# Layer 2: Overlay shared backend assets (skills, config per backend type)
aws s3 sync "s3://$STATE_BUCKET/shared/$OPENAB_BACKEND_AGENT/" "$HOME/" || true

# Layer 3: Overlay shared AGENTS.md (always wins)
aws s3 cp "s3://$STATE_BUCKET/shared/AGENTS.md" "$HOME/" || true

# ghp: gh CLI shim that routes reads through ghpool
chmod +x "$HOME/bin/ghp" 2>/dev/null || true
ln -sf "$HOME/bin/ghp" "$HOME/bin/gh" 2>/dev/null || true
