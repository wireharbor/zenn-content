#!/usr/bin/env bash
# 共有 git hook を有効化する。
# 新規クローン時に 1 回だけ実行してください: bash scripts/setup_githooks.sh
#
# 仕組み: core.hooksPath を .githooks に切り替えるだけ。
# .githooks/ は git 管理下にあり、hook の更新は通常の git pull で配布される。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$WORKSPACE_ROOT"

if [[ ! -d .githooks ]]; then
  echo "ERROR: .githooks/ が見つかりません: $WORKSPACE_ROOT" >&2
  exit 1
fi

# Windows 環境では実行ビットが効かないことがあるため、git index 上で +x を付ける
for hook in .githooks/*; do
  [[ -f "$hook" ]] || continue
  case "$hook" in
    *.sample|*.md) continue ;;
  esac
  chmod +x "$hook" 2>/dev/null || true
  git update-index --chmod=+x "$hook" 2>/dev/null || true
done

git config core.hooksPath .githooks

echo "✓ core.hooksPath を .githooks に設定しました"
echo ""
echo "有効になった hook:"
for hook in .githooks/*; do
  [[ -f "$hook" ]] || continue
  case "$hook" in
    *.sample|*.md) continue ;;
  esac
  echo "  - $(basename "$hook")"
done
