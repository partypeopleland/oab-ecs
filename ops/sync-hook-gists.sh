#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BOTS_FILE="$SCRIPT_DIR/bots.yaml"
HOOKS_DIR="$ROOT_DIR/hooks"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "錯誤: 找不到必要工具 '$1'"
    exit 1
  fi
}

parse_gist_id() {
  local url="$1"
  local normalized="${url%%\?*}"
  echo "$normalized" | sed -E 's#https://gist\.githubusercontent\.com/[^/]+/([^/]+)/raw(/.*)?#\1#'
}

parse_gist_filename() {
  local url="$1"
  local normalized="${url%%\?*}"
  basename "$normalized"
}

collect_bots() {
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@"
  else
    yq eval 'keys | .[]' "$BOTS_FILE"
  fi
}

sync_hook() {
  local hook_file="$1"
  local url_field="$2"
  local sha_field="$3"
  shift 3
  local bots=("$@")
  local local_path="$HOOKS_DIR/$hook_file"
  local local_sha
  local all_bots

  if [ ! -f "$local_path" ]; then
    echo "錯誤: 找不到 hook 檔案 $local_path"
    exit 1
  fi

  local_sha="$(sha256sum "$local_path" | awk '{print $1}')"
  echo "同步 $hook_file ..."
  echo "  本地 SHA256: $local_sha"

  declare -A seen_urls=()
  mapfile -t all_bots < <(yq eval 'keys | .[]' "$BOTS_FILE")

  for bot in "${bots[@]}"; do
    local hook_url
    hook_url="$(yq eval -r ".${bot}.${url_field}" "$BOTS_FILE")"
    if [ -z "$hook_url" ] || [ "$hook_url" = "null" ]; then
      echo "錯誤: bots.yaml 中 $bot 缺少 ${url_field}"
      exit 1
    fi

    if [ -n "${seen_urls[$hook_url]:-}" ]; then
      continue
    fi
    seen_urls["$hook_url"]=1

    local gist_id
    local gist_filename
    local remote_sha
    gist_id="$(parse_gist_id "$hook_url")"
    gist_filename="$(parse_gist_filename "$hook_url")"

    if [ -z "$gist_id" ] || [ "$gist_id" = "$hook_url" ]; then
      echo "錯誤: 無法從 URL 解析 gist id: $hook_url"
      exit 1
    fi

    echo "  更新 gist: $gist_id ($gist_filename)"
    if ! gh api --method PATCH "gists/$gist_id" \
      -F "files[$gist_filename][content]=@$local_path" \
      > /dev/null; then
      echo "錯誤: 無法更新 gist $gist_id，請檢查 gh 登入狀態與寫入權限。"
      exit 1
    fi

    # 使用 gh api 取得 Gist 最新內容以避免 CDN 快取延遲
    remote_sha="$(gh api "gists/$gist_id" | jq -j ".files[\"$gist_filename\"].content" | sha256sum | awk '{print $1}')"
    if [ "$remote_sha" != "$local_sha" ]; then
      echo "錯誤: gist 更新後 SHA256 不一致"
      echo "  URL: $hook_url"
      echo "  預期: $local_sha"
      echo "  實際: $remote_sha"
      exit 1
    fi
  done

  for bot in "${all_bots[@]}"; do
    local hook_url
    hook_url="$(yq eval -r ".${bot}.${url_field}" "$BOTS_FILE")"
    if [ -n "${seen_urls[$hook_url]:-}" ]; then
      yq eval -i ".${bot}.${sha_field} = \"$local_sha\"" "$BOTS_FILE"
    fi
  done

  echo "  已更新 bots.yaml 欄位 ${sha_field}"
}

main() {
  require_cmd gh
  require_cmd yq
  require_cmd jq
  require_cmd curl
  require_cmd sha256sum

  if [ ! -f "$BOTS_FILE" ]; then
    echo "錯誤: 找不到 $BOTS_FILE"
    exit 1
  fi

  if ! gh auth status >/dev/null 2>&1; then
    echo "錯誤: gh 尚未登入，請先執行 gh auth login"
    exit 1
  fi

  mapfile -t bots < <(collect_bots "$@")
  if [ "${#bots[@]}" -eq 0 ]; then
    echo "錯誤: 沒有可同步的 bot"
    exit 1
  fi

  for bot in "${bots[@]}"; do
    if ! yq eval -e ".${bot}" "$BOTS_FILE" >/dev/null 2>&1; then
      echo "錯誤: bots.yaml 中找不到 bot '$bot'"
      exit 1
    fi
  done

  echo "將同步以下 bot 的 hook gist: ${bots[*]}"
  sync_hook "pre-boot.sh" "pre_boot_url" "pre_boot_sha256" "${bots[@]}"
  sync_hook "pre-shutdown.sh" "pre_shutdown_url" "pre_shutdown_sha256" "${bots[@]}"
  echo "完成。請檢查 bots.yaml 變更後再 deploy。"
}

main "$@"
