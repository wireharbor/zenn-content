---
title: "最短ルートのおさらい"
free: true
---

note 連載 6 記事で通した「動かすまで」の最短ルートを、本書の読者向けに要約します。連載を読み終えている方は飛ばして第 3 章に進んでかまいません。

## ゴールの画

スマートフォンの ChatGPT アプリまたは Claude.ai アプリに日本語で「今の維持率は？」「今のポートフォリオで気になる点は？」と問いかけると、自分の最新のポートフォリオデータを読んで答えが返ってくる状態を作ります。

## 全体構成

```
Google Sheets / CSV
        ↓  （手元で読み出す）
Python スクリプト main.py
        ↓  （FastAPI でラップ）
ローカル API（http://localhost:8000/portfolio）
        ↓  （GitHub → Render）
公開 API（https://〇〇.onrender.com/portfolio）
        ↓
ChatGPT の Custom GPT（OpenAPI スキーマで接続）
Claude.ai の Custom Connector（MCP サーバー経由で接続）
        ↓
スマホアプリから日本語で問う
```

以降の 4 Step は骨子だけです。画面単位の手順は連載の該当記事にあります。

## Step 1: エージェントを用意する

Claude Code Desktop か Codex のデスクトップアプリをインストールします。本書の以降の手順もすべて「エージェントに依頼する」前提で書いています。

- Claude Code Desktop: https://claude.ai/download（Claude Pro / Max / Team / Enterprise が必要）
- Codex: https://developers.openai.com/codex/app（ChatGPT Plus 以上に含まれる）

Claude は Chat / Cowork / Code の3タブのうち **Code** タブを、Codex は実行モード **Local** を選びます。プロジェクトのフォルダ（例: `portfolio-ai`）を指定したら準備完了です。

詳細は [連載 Step 1](https://note.com/wireharbor/n/n11706f454e50)。

## Step 2: 資産データを読み出すスクリプトを作る

プロジェクトフォルダに `main.py` を作り、Google Sheets または CSV から資産データを読んで画面に表示するスクリプトにします。エージェントに次のように依頼します。

> 自分のポートフォリオデータをAIに相談できるようにしたい。そのためにまず、自分のGoogleスプレッドシート（またはCSV）から資産データを読み出すPythonスクリプトを作ってほしい。ファイル名は仮に main.py にする。必要な準備（Pythonのインストール、ライブラリの追加、Google認証の設定など）も順を追って全部教えて。詰まったら聞くから対話しながら進めて

ターミナルで `python main.py` を実行して、自分の資産データが画面に表示されれば完了。

詳細は [連載 Step 2](https://note.com/wireharbor/n/nc0b90f1dd81b)。

## Step 3: 手元のスクリプトを公開 API にする

`main.py` を FastAPI でラップし、GitHub にアップロードして、Render などのクラウドサービスにデプロイします。エージェントに次のように依頼します。

> Step 2で作った、資産データを読むPythonファイル（main.py）が手元にある。これをインターネット上に置いてURLで叩ける形にしたい。必要な書き換え、ライブラリの追加、GitHubへのアップロード、クラウド側の設定まで、手順を順番に全部案内して

ブラウザで `https://〇〇.onrender.com/portfolio` を開いて JSON が返れば完了。このURLが Step 4 で AI アプリに登録するエンドポイントになります。

詳細は [連載 Step 3（有料）](https://note.com/wireharbor/n/n4ce581d0a19e)。

## Step 4a: ChatGPT に繋ぐ（GPT Builder）

https://chatgpt.com/gpts/editor を開き、Configure タブの **Actions** セクションに OpenAPI スキーマを貼ります。スキーマは curl で実レスポンスを確認してからエージェントに書かせるのが速いです。

最小スキーマはこの形です。

```yaml
openapi: 3.1.0
info:
  title: My Portfolio API
  version: 1.0.0
servers:
  - url: https://あなたのサービス名.onrender.com
paths:
  /portfolio:
    get:
      operationId: getPortfolio
      summary: 現在のポートフォリオのスナップショットをJSONで返す
      responses:
        '200':
          description: 現在のポジション一覧
```

保存後、ChatGPT モバイルアプリの **My GPTs** から作った GPT を選び「今の維持率は？」と聞いて答えが返れば完了。

詳細は [連載 Step 4a（有料）](https://note.com/wireharbor/n/n26a6ced93209)。

## Step 4b: Claude.ai に繋ぐ（Custom Connector）

Claude.ai の Custom Connector は **MCP サーバー**形式のURLを受け付けます。GPT Builder の OpenAPI 直叩きとは仕組みが違うので、Step 3 でデプロイした FastAPI に `/mcp` エンドポイントを足す書き換えが必要です。エージェントに次のように依頼します。

> Step 3でデプロイしたFastAPI（https://〇〇.onrender.com/portfolio）を、Claude.aiのCustom Connectorに登録できるようにしたい。既存の /portfolio エンドポイントは残したまま、同じアプリに MCP サーバーとしても答える口（/mcp など）を足してほしい。必要なライブラリ（fastmcp など）のインストール、コードの書き換え、Render への再デプロイまで順に案内して

再デプロイ後に得た `https://〇〇.onrender.com/mcp` を Claude.ai の https://claude.ai/settings/connectors に登録します。モバイルアプリで Connector をオンにして同じ問いを投げれば完了。

詳細は [連載 Step 4b](https://note.com/wireharbor/n/nc42749583baf)。

## なぜ Render を例にするか

個人の毎日運用で使う範囲なら無料枠で足り、GitHub を繋げば自動でデプロイが走るからです。15 分アクセスがないとスリープして次の最初のアクセスに数十秒かかる制約はありますが、毎朝1回確認する用途では許容できます。

スリープへの対処、他プラットフォーム（Railway / fly.io / Vercel）との比較、移行手順は **第 V 部（第 12-13 章）** で扱います。

## ここまでが連載、ここから先が本書

最短ルートで出てくる手順は、断片なら日本語で検索すれば見つかります。ただ「手元スクリプト → 公開API → モバイルAIの口に登録」の全工程を一本でつなげた日本語の記事が少なく、連載ではその糸を通しました。

本書は糸が通った後に出てくる問題を扱います。代表的なものを挙げると:

- Render が朝の最初のアクセスで遅い → **第 5 章（デプロイ編のエラー図鑑）**
- MCP サーバーと GPT Builder でレスポンスが違う → **第 6 章（接続編のエラー図鑑）**
- 公開 URL に誰でもアクセスできてしまう → **第 III 部（セキュリティ設計）**
- データが昨日のままで今日の値が読めない → **第 14 章（データの新鮮さ）**
- ニュースや相場急変と連動して毎朝レポートが欲しい → **第 VII 部（ユースケース）**

連載を通した読者には、ここから先が「次に欲しかったもの」のはずです。

## 連載リンクまとめ

各記事の詳細手順は連載を参照してください。

- [フック記事](https://note.com/wireharbor/n/nfdc793f3996c)
- [Step 1 — AIエージェントを用意する](https://note.com/wireharbor/n/n11706f454e50)
- [Step 2 — 資産データ読み出しスクリプト](https://note.com/wireharbor/n/nc0b90f1dd81b)
- [Step 3 — クラウドAPIデプロイ（300円）](https://note.com/wireharbor/n/n4ce581d0a19e)
- [Step 4a — GPT Builder 接続（300円）](https://note.com/wireharbor/n/n26a6ced93209)
- [Step 4b — Claude.ai Custom Connector](https://note.com/wireharbor/n/nc42749583baf)
