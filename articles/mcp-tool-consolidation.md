---
title: "MCP サーバーのツールを7個から3個に統合した設計判断と手順"
emoji: "🔧"
type: "tech"
topics: ["mcp", "claudecode", "python", "fastmcp", "ai"]
published: true
---

## はじめに

Claude Code や ChatGPT から呼び出す MCP (Model Context Protocol) サーバーを個人で運用しています。ポートフォリオのダッシュボードを表示するサーバーで、最初は7個のツールがありました。

使い続けるうちに問題が出てきたので、3個に統合しました。この記事では、なぜ統合したか、どう判断したか、具体的な手順を書きます。

:::message
この記事は [note の Claude Code 運用シリーズ](https://note.com/wireharbor/) と連動しています。note では体験談寄り、Zenn では技術寄りの内容を書いています。
:::

## 統合前の状態: 7ツール

統合前のツール構成です。

| ツール名 | 用途 |
|---|---|
| `get_snapshot_summary` | スナップショットの要約を返す |
| `get_snapshot_section` | 特定セクションのデータを返す |
| `get_timeseries` | NAV/リターンの時系列データを返す |
| `render_portable_dashboard` | ChatGPT/CLI 向けダッシュボード生成 |
| `render_claude_dashboard` | Claude.ai 向けダッシュボード生成 |
| `handle_portfolio_request` | 自然言語リクエストのルーティング |
| `get_mode_context` | モード別のコンテキスト情報を返す |

他にも `render_portfolio_dashboard`（旧名の互換スタブ）と `get_dashboard_payload`（生データ取得）がありました。

## 何が問題だったか

### 1. LLM がツールを選び間違える

7個のツールがあると、LLM は似た名前のツールを混同します。`render_portable_dashboard` と `render_portfolio_dashboard` を間違えるのは日常茶飯事でした。

description を工夫しても限界があります。ChatGPT は特に、最初に見つけた「それっぽい名前」のツールを呼ぶ傾向がありました。

### 2. 呼び出し回数が増える

「ダッシュボードを見せて」というリクエストに対して、LLM は以下の手順を踏んでいました:

1. `get_mode_context` でモードを判定
2. `handle_portfolio_request` でルーティング
3. `render_portable_dashboard` でダッシュボード生成

3回の往復が必要です。1回で済むべきです。

### 3. guidance の分散

「この後ウェブ検索が必要か」「どの深さで回答すべきか」といった LLM 向けのガイダンスが、複数のツールに散らばっていました。ツールの呼び出し順序によってガイダンスが欠落する問題が起きていました。

## 統合の判断基準

以下の基準で「統合すべきか、残すべきか」を判断しました。

### 統合する条件

- **単独で呼ぶ意味がない**: `get_mode_context` は必ず他のツールと組み合わせて使う。単独では価値がない
- **LLM が混同する**: 名前や用途が似ていて、description だけでは区別できない
- **1回の呼び出しで返せる**: 返すデータ量が合理的な範囲に収まる

### 残す条件

- **独立したユースケースがある**: `get_timeseries` は時系列データを返す専用ツール。ダッシュボードとは別の用途で使う
- **プラットフォーム固有の処理がある**: `render_claude_dashboard` は Claude.ai のアーティファクト向けに HTML + CSS を返す。`render_portable_dashboard` とは出力形式が根本的に異なる

## 統合後の状態: 3ツール（+ ユーティリティ2個）

### メインツール

| ツール名 | 用途 |
|---|---|
| `render_portable_dashboard` | ChatGPT/CLI/Codex 向け。モード判定・guidance・ダッシュボード生成を1回で返す |
| `render_claude_dashboard` | Claude.ai 向け。HTML + CSS + デザインルールを返す |
| `get_snapshot_summary` | スナップショット要約。分析系の質問に直接回答する用途 |

### ユーティリティ

| ツール名 | 用途 |
|---|---|
| `get_snapshot_section` | 特定セクションの詳細データ |
| `get_timeseries` | 時系列データ（独自計算用） |

統合前の7個から、実質3個（+ 用途の明確なユーティリティ2個）になりました。

## 具体的な統合手順

### Step 1: 主力ツールに機能を集約

`render_portable_dashboard` に以下を集約しました:

- **モード判定**: `user_message` から自動でモード（analysis / margin / news / strategy）を判定
- **guidance**: モード別の回答ガイドラインを `guidance` フィールドで返す
- **requires_web_search**: ウェブ検索が必要かどうかのフラグ
- **reply_hints**: 回答時の注意点
- **snapshot_focus**: どのセクションに注目すべきか

```python
# 統合後の返り値（イメージ）
{
    "dashboard_markdown": "...",
    "signed_url": "https://...",
    "guidance": "分析モードでは数値の根拠を...",
    "requires_web_search": False,
    "reply_hints": ["円建て表示を優先", "前月比を含める"],
    "snapshot_focus": ["allocation", "performance"],
    "display_mode": "analysis"
}
```

### Step 2: 旧ツールを deprecated stub に

いきなり削除せず、まず deprecated stub にしました。旧ツールが呼ばれたら、内部で `render_portable_dashboard` に委譲します。

```python
# deprecated stub の例
def handle_portfolio_request(user_message: str) -> dict:
    """[DEPRECATED] Use render_portable_dashboard instead."""
    return render_portable_dashboard(user_message=user_message)
```

この段階で全テスト（127 tests）を通しました。

### Step 3: 観察期間

2日間、実際の運用で旧ツール名が呼ばれないことを確認しました。server instructions に「`render_portable_dashboard` を使うこと」と明記したので、LLM は新しいツールを呼ぶようになっていました。

### Step 4: stub 削除

観察期間を経て、deprecated stub を完全削除しました。テスト・export・validate も同時に更新。

## 統合の効果

### ツール選択ミスが消えた

7個 → 3個になったことで、LLM がツールを選び間違えることがほぼなくなりました。特に ChatGPT での誤選択が激減しました。

### 往復回数が減った

「ダッシュボードを見せて」に対して:

- 統合前: 3回の往復（mode判定 → ルーティング → ダッシュボード生成）
- 統合後: 1回の往復（`render_portable_dashboard` 1発）

### guidance の欠落がなくなった

全ての情報が1回のレスポンスに含まれるので、呼び出し順序によるガイダンス欠落が構造的に起きなくなりました。

## 教訓

### 「ツールを足す」より「ツールを減らす」方が難しい

機能を追加するときは新しいツールを作りがちですが、LLM から見ると選択肢が増えるほど混乱します。**LLM が「どれを呼べばいいか」迷わない構成**を目指すべきです。

### deprecated stub は安全ネット

いきなり削除せず stub を挟むことで、既存の呼び出しパターンを壊さずに移行できます。テストが通る状態を維持したまま段階的に移行するのが安全です。

### プラットフォーム固有は分ける価値がある

ChatGPT 向けと Claude.ai 向けでは出力形式が根本的に異なります（Markdown vs HTML artifact）。これを1つのツールに押し込むと、条件分岐が増えて保守性が下がります。

## まとめ

- MCP ツールが多すぎると LLM が混同する。3個前後が目安
- 統合判断: 「単独で呼ぶ意味があるか」「LLM が区別できるか」で決める
- 移行は段階的に: 集約 → deprecated stub → 観察 → 削除
- 1回の呼び出しで必要な情報を全て返す設計にすると、往復回数もガイダンス欠落も減る
