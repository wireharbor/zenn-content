#!/usr/bin/env bash
# 公開前スキャン — push/publish 前に、公開成果物に自サーバーの識別子が混入していないか検出する
# 由来: 2026-04-19 の portfolio_ai_guide Zenn Book 公開準備で、実稼働 URL・内部 env 名・
#       内部ファイル名・内部クラス名・内部 repo 名が本文に含まれていた事例
# 使い方:
#   bash scripts/scan_public_exposure.sh <ディレクトリ>  — 指定ディレクトリを再帰スキャン
#   bash scripts/scan_public_exposure.sh --push         — pre-push hook 用（stdin から refs を読む）
#
# 対象ファイル: *.md, *.json, *.yaml, *.yml, *.html
# 除外パス: 内部 repo 配下（公開しない前提の場所）は除く

set -euo pipefail

# 禁止キーワード（公開される成果物に含まれてはいけない内部識別子）
BANNED_PATTERNS=(
  # 実稼働 URL / ドメイン
  'portfolio-bridge\.onrender\.com'
  'wireharbor\.onrender\.com'
  # 内部プロジェクト固有 env
  'PORTFOLIO_API_TOKEN'
  'PORTFOLIO_LINK_SECRET'
  'PORTFOLIO_MCP_OAUTH_APPROVAL_SECRET'
  'PORTFOLIO_MCP_OAUTH_STATE_MODE'
  'PORTFOLIO_SIGNED_LINKS_ENABLED'
  'PORTFOLIO_PUBLIC_BASE_URL'
  # 内部ファイル名（portfolio-bridge snapshot 構成）
  'snapshot_values\.md'
  'nav_history\.json'
  'scenario_snapshot\.json'
  'analytics\.json'
  # 内部コード・クラス・関数名
  '_McpAcceptFixer'
  'get_portfolio_news_drivers'
  'render_claude_dashboard'
  'render_portable_dashboard'
  'render_portable_news'
  'finalize_for_chatgpt'
  'finalize_for_claude'
  'BridgeSecurity'
  'CLAUDE_NEWS_ALLOWED_KEYS'
  'PORTABLE_NEWS_ALLOWED_KEYS'
  # 内部 repo 名
  'portfolio-bridge'
  'audit-automation'
  'mf-sync'
  'private-research'
  'browser-runtime'
  'wireharbor-workspace'
)

# 除外パス（内部 repo やルール文書は公開対象ではない）
EXCLUDE_PATHS=(
  '^portfolio-bridge/'
  '^audit-automation/'
  '^mf-sync/'
  '^private-research/'
  '^browser-runtime/'
  '^scripts/'
  '^\.agents/'
  '^\.githooks/'
  '^rules/'
  '^historical/'
  '^note-ops/scripts/'
  '^note-ops/docs/'
  '^note-ops/signals/'
  '^note-ops/review/'
  'scan_public_exposure\.sh'
  'scan_secrets\.sh'
)

TARGET="${1:-}"
FOUND=0

should_exclude() {
  local file="$1"
  for exc in "${EXCLUDE_PATHS[@]}"; do
    if echo "$file" | grep -qE "$exc"; then
      return 0
    fi
  done
  return 1
}

scan_content() {
  local file="$1"
  local content="$2"
  local is_diff="${3:-false}"
  if should_exclude "$file"; then
    return
  fi
  # diff モードでは追加行（^+）のみ対象。削除行（^-）は既に公開から消えているので無視
  if [[ "$is_diff" == "true" ]]; then
    content=$(echo "$content" | grep -E '^\+' | grep -v '^\+\+\+' || true)
    [[ -z "$content" ]] && return
  fi
  for pattern in "${BANNED_PATTERNS[@]}"; do
    matches=$(echo "$content" | grep -inE "$pattern" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
      echo "⚠ $file"
      echo "$matches" | head -3
      echo ""
      FOUND=$((FOUND + 1))
    fi
  done
}

ZERO_SHA="0000000000000000000000000000000000000000"

if [[ "$TARGET" == "--push" ]]; then
  echo "=== push 対象差分の公開キーワードスキャン ==="
  while read -r local_ref local_sha remote_ref remote_sha; do
    [[ "$local_sha" == "$ZERO_SHA" ]] && continue

    if [[ "$remote_sha" == "$ZERO_SHA" ]]; then
      mapfile -t files < <(git log --name-only --pretty=format: "$local_sha" --not --remotes 2>/dev/null | sort -u | grep -v '^$' || true)
      for file in "${files[@]}"; do
        [[ -z "$file" ]] && continue
        content=$(git log -p "$local_sha" --not --remotes -- "$file" 2>/dev/null || true)
        scan_content "$file" "$content" true
      done
    else
      while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        content=$(git diff "$remote_sha..$local_sha" -- "$file" 2>/dev/null || true)
        scan_content "$file" "$content" true
      done < <(git diff --name-only --diff-filter=ACM "$remote_sha..$local_sha" 2>/dev/null)
    fi
  done
elif [[ -z "$TARGET" ]]; then
  echo "使い方: $0 <target_dir> | $0 --push"
  exit 1
else
  echo "=== $TARGET の公開キーワードスキャン ==="
  while IFS= read -r file; do
    content=$(cat "$file" 2>/dev/null || true)
    scan_content "$file" "$content"
  done < <(find "$TARGET" -type f \( -name "*.md" -o -name "*.json" -o -name "*.yaml" -o -name "*.yml" -o -name "*.html" \) ! -path "*/node_modules/*" ! -path "*/.git/*")
fi

if [[ "$FOUND" -gt 0 ]]; then
  echo "🛑 公開キーワードが ${FOUND} 件見つかりました — 公開前に置換または削除してください"
  exit 1
else
  echo "✓ 公開キーワードは検出されませんでした"
  exit 0
fi
