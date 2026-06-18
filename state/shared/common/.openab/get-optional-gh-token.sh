#!/bin/sh
set -eu

SECRET_PATH="${1:-}"
[ -n "$SECRET_PATH" ] || exit 0
command -v aws >/dev/null 2>&1 || exit 0

SECRET_JSON="$(
  aws secretsmanager get-secret-value \
    --secret-id "$SECRET_PATH" \
    --query 'SecretString' \
    --output text 2>/dev/null || true
)"

[ -n "$SECRET_JSON" ] || exit 0

printf '%s' "$SECRET_JSON" \
  | tr -d '\n' \
  | sed -n 's/.*"GH_TOKEN"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
