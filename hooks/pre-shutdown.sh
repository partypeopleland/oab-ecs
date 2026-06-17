#!/bin/sh
set -e

# Env vars expected: STATE_BUCKET, OPENAB_AGENT_NAME

# Fallback HOME if not defined
HOME="${HOME:-/home/agent}"
export PATH="$HOME/bin:$PATH"

if [ -n "$STATE_BUCKET" ]; then
  echo "正在備份當前環境狀態至 S3..."
  # 打包 /home/agent (即 $HOME) 目錄，排除大的暫存與系統目錄
  tar -czf /tmp/home-backup.tar.gz -C "$HOME" \
    --exclude="./aws-cli" \
    --exclude="./bin/aws" \
    --exclude="./.cache" \
    --exclude="./.npm" \
    --exclude="./node_modules" \
    --exclude="./.rustup" \
    --exclude="./.cargo" \
    --exclude="./.local/share/uv/cache" \
    --exclude="./.local/aws-cli" \
    --exclude="./.openab/logs" \
    --exclude="./.openab/tmp" \
    --exclude="./tmp" \
    . 2>/dev/null || [ $? -le 2 ]
  
  # 上傳至 S3
  aws s3 cp /tmp/home-backup.tar.gz "s3://$STATE_BUCKET/$OPENAB_AGENT_NAME-home.tar.gz" --quiet || true
  rm -f /tmp/home-backup.tar.gz
  echo "✓ 備份完成！"
fi
