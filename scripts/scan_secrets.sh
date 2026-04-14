#!/usr/bin/env bash
# 秘密情報スキャン — commit/push 前に実行して漏洩を検出する
# 由来: engineering:code-review スキルのセキュリティ観点をスクリプト化
# 使い方:
#   bash scripts/scan_secrets.sh                — git diff --cached の変更ファイル（pre-commit 向け）
#   bash scripts/scan_secrets.sh <ディレクトリ>  — 指定ディレクトリを再帰スキャン
#   bash scripts/scan_secrets.sh --push         — pre-push hook 用。stdin から
#                                                 「<local_ref> <local_sha> <remote_ref> <remote_sha>」を読み、
#                                                 push される差分をスキャン（.githooks/pre-push から呼ばれる）

set -euo pipefail

# パターン定義（正規表現）
PATTERNS=(
  # API キー・トークン
  'ANTHROPIC_API_KEY\s*=\s*sk-ant-'
  'OPENAI_API_KEY\s*=\s*sk-'
  'api[_-]?key\s*[:=]\s*["\x27][A-Za-z0-9_\-]{20,}'
  'token\s*[:=]\s*["\x27][A-Za-z0-9_\-]{20,}'
  'secret\s*[:=]\s*["\x27][A-Za-z0-9_\-]{20,}'
  # Google サービスアカウント
  '"private_key"\s*:\s*"-----BEGIN'
  '"client_email"\s*:.*\.iam\.gserviceaccount\.com'
  # Render / Heroku
  'RENDER_API_KEY'
  'HEROKU_API_KEY'
  # パスワード（ハードコード）
  'password\s*[:=]\s*["\x27][^\s]{8,}'
)

# 除外パターン（テスト用ダミー、ドキュメント例示）
EXCLUDES=(
  'test_.*\.py'
  'example'
  'placeholder'
  'YOUR_.*_HERE'
  'xxx'
  'scan_secrets\.sh'
)

TARGET="${1:-}"
FOUND=0

scan_content() {
  local file="$1"
  local content="$2"
  for pattern in "${PATTERNS[@]}"; do
    matches=$(echo "$content" | grep -inE "$pattern" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
      # 除外チェック
      skip=false
      for exc in "${EXCLUDES[@]}"; do
        if echo "$file $matches" | grep -qiE "$exc"; then
          skip=true
          break
        fi
      done
      if [[ "$skip" == "false" ]]; then
        echo "⚠ $file"
        echo "$matches" | head -3
        echo ""
        FOUND=$((FOUND + 1))
      fi
    fi
  done
}

ZERO_SHA="0000000000000000000000000000000000000000"

if [[ "$TARGET" == "--push" ]]; then
  # pre-push hook モード: stdin から push される refs を読み、push 差分をスキャン
  echo "=== push 対象差分の秘密情報スキャン ==="
  while read -r local_ref local_sha remote_ref remote_sha; do
    # ref 削除 push（local_sha がゼロ）はスキャン対象外
    [[ "$local_sha" == "$ZERO_SHA" ]] && continue

    if [[ "$remote_sha" == "$ZERO_SHA" ]]; then
      # 新ブランチ push: remotes に無い commits の名前/差分を取る
      mapfile -t files < <(git log --name-only --pretty=format: "$local_sha" --not --remotes 2>/dev/null | sort -u | grep -v '^$' || true)
      for file in "${files[@]}"; do
        [[ -z "$file" ]] && continue
        content=$(git log -p "$local_sha" --not --remotes -- "$file" 2>/dev/null || true)
        scan_content "$file" "$content"
      done
    else
      # 既存ブランチ更新: remote..local の差分
      while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        content=$(git diff "$remote_sha..$local_sha" -- "$file" 2>/dev/null || true)
        scan_content "$file" "$content"
      done < <(git diff --name-only --diff-filter=ACM "$remote_sha..$local_sha" 2>/dev/null)
    fi
  done
elif [[ -z "$TARGET" ]]; then
  # staged files モード
  echo "=== staged ファイルの秘密情報スキャン ==="
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    content=$(git diff --cached -- "$file" 2>/dev/null || true)
    scan_content "$file" "$content"
  done < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)
else
  # ディレクトリスキャンモード
  echo "=== $TARGET の秘密情報スキャン ==="
  while IFS= read -r file; do
    content=$(cat "$file" 2>/dev/null || true)
    scan_content "$file" "$content"
  done < <(find "$TARGET" -type f \( -name "*.py" -o -name "*.mjs" -o -name "*.js" -o -name "*.json" -o -name "*.env" -o -name "*.yaml" -o -name "*.yml" -o -name "*.toml" -o -name "*.sh" -o -name "*.md" \) ! -path "*/node_modules/*" ! -path "*/.git/*" ! -path "*/venv/*")
fi

if [[ "$FOUND" -gt 0 ]]; then
  echo "🛑 秘密情報の疑いが ${FOUND} 件見つかりました"
  exit 1
else
  echo "✓ 秘密情報は検出されませんでした"
  exit 0
fi
