---
title: "エラー図鑑（4）接続編"
free: false
---

この章では、デプロイが成功してクラウドから `/portfolio` や `/mcp` の URL が返るようになった後、**GPT Builder の Action や Claude.ai の Custom Connector と繋ぐ段階で出るエラー** 6 種を扱います。

接続段階のエラーは「サーバーは動いているのに AI から見えない・呼ばれない」という形で出るため、問題の切り分けが一番難しい層です。まずは **サーバーが 200 で返しているか** を curl などで確認してから、この章の各項目に移ってください。

MCP プロトコルの内部仕様（transport、annotation の意味、token 計算）に踏み込んだ解説は第 10 章で扱います。この章は「とりあえず動かす」ための症状別カタログです。

## 1. GPT Builder の Test で `401 Unauthorized`

### 症状

GPT Builder の Configure → Actions で OpenAPI スキーマを貼り、「Test」ボタンを押すと:

```
401 Unauthorized
```

または

```
Authentication required
```

ブラウザで同じ URL を開くと JSON が返ってくる。

### 原因

Action の **Authentication 設定と、実 API の認証要件がズレて** います。パターン:

- 実 API は認証なしで誰でも叩ける。しかし GPT Builder 側で「API Key」を選んで空欄のトークンを送っている
- 実 API は Bearer トークンが必要。しかし GPT Builder 側で「None」を選んでいる
- Bearer の形式が違う（`Bearer xxxxx` を期待しているのに `xxxxx` だけを送っている、など）

### 対処

1. 実 API が認証を要求するかを先に確定する。ターミナルから:
   ```
   curl -v https://〇〇.onrender.com/portfolio
   ```
   - 200 で JSON が返るなら認証なし
   - 401 / 403 で返るなら認証あり
2. 認証なしなら、GPT Builder → Action の **Authentication** を「None」に設定
3. 認証ありなら「API Key」を選び、Auth Type を **Bearer** にしてトークンを貼る（単なる `xxxxx` だけを入れれば、GPT Builder 側が `Bearer xxxxx` の形に整形して送ります）
4. Save して Test を押し直す

## 2. Test は通るが JSON のパースに失敗（スキーマと実レスポンスのズレ）

### 症状

Test は緑の ✓ で成功する。しかし実際に GPT に「今の維持率は？」と聞くと:

```
データ解析に失敗しました
```

や「レスポンスの形式が期待と違う」と言われる。

### 原因

OpenAPI スキーマで書いた **レスポンスの shape と、API が実際に返す JSON が合っていない** のが典型です。たとえばスキーマでは:

```yaml
responses:
  '200':
    content:
      application/json:
        schema:
          type: object
          properties:
            maintenance_rate:
              type: number
```

と書いたのに、実 API は `{"data": {"maintenance_rate": 0.5}}` のように一段深くネストしている、など。

### 対処

1. `curl https://〇〇.onrender.com/portfolio` で実レスポンスの JSON を確認
2. その構造に合わせてスキーマを書き直す。実レスポンスが `{"data": {"maintenance_rate": ...}}` ならスキーマも `properties.data.properties.maintenance_rate` の形にする
3. スキーマを Action に貼り直し、Save → Test

エージェントに実レスポンスを貼って「これに合う OpenAPI スキーマに書き直して」と頼むのが速いです。

スキーマを手で書き続けるより、API を FastAPI で書いているなら `app.openapi()` で自動生成されたスキーマをそのまま使うほうが確実です。

## 3. GPT が Action を呼ばずに「データがありません」と返す

### 症状

Test は通る。Action の設定も正しい。しかし GPT に「今の維持率は？」と聞くと:

```
申し訳ございませんが、現在のデータは保持していないため、維持率の値をお伝えできません。
```

と Action を呼ばずに一般論を返す。

### 原因

GPT が Action を **「このユーザーの問いに対してこの Action を使うべきだ」と判定できていない** 状態です。

よくある原因:

- Action の `operationId` の summary や description が「getPortfolio」のように無味乾燥で、GPT が用途を推測できない
- GPT 本体の Instructions に「資産の話が来たら getPortfolio を呼ぶ」的な誘導が無い

### 対処

1. OpenAPI スキーマの該当 operation に **日本語で意図の伝わる summary と description** を書く:
   ```yaml
   /portfolio:
     get:
       operationId: getPortfolio
       summary: 現在のポートフォリオのスナップショットを取得する
       description: |
         ユーザーの保有資産、維持率、為替リスク、評価損益のスナップショットを JSON で返す。
         「今の維持率」「今日の損益」「気になる点は」などの質問では必ずこの API を呼ぶ。
   ```
2. GPT Builder の Configure タブの **Instructions** 欄に、Action を呼ぶ条件を明示:
   ```
   ユーザーに資産や維持率、ポートフォリオについて聞かれたら、
   まず getPortfolio を呼び出して最新データを取得してから回答すること。
   自分の記憶やChatGPTの一般知識で答えない。
   ```
3. Save して聞き直す

Instructions は Action の「いつ使うか」を埋めるのが役割です。スキーマ側で operationId を英語で書いても、Instructions で「資産の話はこれを呼ぶ」と日本語で指示するほうが効きます。

## 4. Claude.ai で "Connected, 0 tools" と表示される

### 症状

Claude.ai の Settings → Connectors で MCP サーバーの URL を追加すると、一覧には「Connected（緑）」と出る。しかし Connector をオンにして会話で呼ぼうとしても、tool として認識されない。Connector の詳細画面を開くと:

```
Available tools: 0
```

### 原因

MCP サーバーの URL には繋がっているが、**`tools/list` の応答に tool が入っていない** か、レスポンスフォーマットが MCP の仕様に合っていない状態です。よくあるパターン:

- FastAPI の手書き MCP 実装で、tool 定義を返すエンドポイントに何も登録していない
- `fastmcp` を使っているが、`@server.tool()` デコレータを外したまま push してしまった
- Claude.ai 側がセッション初期化に失敗している（Render の cold start でタイムアウトしてその後リトライしない）

### 対処

1. MCP サーバーの tool list を手で叩いて確認:
   ```
   curl -X POST https://〇〇.onrender.com/mcp \
     -H "Content-Type: application/json" \
     -H "Accept: application/json, text/event-stream" \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
   ```
   返ってくる JSON の `result.tools` 配列が空なら、サーバー側で tool 登録されていない
2. `fastmcp` を使っている場合、ソースに `@mcp.tool()` が付いた関数が 1 つ以上あり、`mcp.run()` または ASGI マウントが動いていることを確認
3. cold start が疑わしい場合、一度 Claude.ai の Connector を削除して再登録（セッション初期化のやり直し）
4. Render を warm に保つ（第 5 章 1 項の対処を参照）

## 5. MCP レスポンスが大きすぎて切れる / 要約が薄くなる

### 症状

ChatGPT 側:
```
Response was truncated because it was too large.
```

Claude.ai 側:
```
[要点だけ返ってくるが、具体的な数値や銘柄名が落ちている]
```

### 原因

MCP / Action のレスポンス JSON が、AI 側の **1 ツール呼び出しあたりの上限** を超えています。おおまかな目安:

- ChatGPT Action: **45KB 前後** が上限。それ以上は切られる
- Claude.ai MCP: **20,000 token 前後**（日本語で約 40,000 字）。大きすぎると Claude が読み込みはするが回答に反映しきれなくなる（詳細は第 10 章）

保有銘柄 100 本 × 各銘柄に 20 項目のメタデータを返していると、すぐこの壁に当たります。

### 対処

1. **フィルタ済みの軽量版を返すツールを分ける**: `get_summary`（維持率・評価損益など 10 key 程度だけ）と `get_full`（全銘柄の詳細）を別ツールにして、AI に summary を先に呼ばせる
2. **プラットフォームごとにレスポンスを変える**: ChatGPT 向けには `/portfolio?platform=chatgpt` で軽量化、Claude 向けは `platform=claude` で別キーに絞る
3. **ツール側の description で「件数を指定できる」ことを伝える**: `get_holdings(limit=10)` のような絞り込み引数を足し、Instructions で「最初は limit=10 で呼ぶ」と誘導する

レスポンスサイズ計測には `curl -s URL | wc -c` で手早く見られます。token ベースで計るときは tiktoken などのライブラリを使います。

## 6. MCP の tool が認識はされるが Claude が呼んでくれない（annotation 漏れ）

### 症状

Claude.ai で「My Portfolio という Connector から使える tool は？」と聞くと一覧には出る。しかし普通の会話で「今の維持率は？」と聞いても tool を呼ばずに「直接のデータアクセスは持っていません」と返す。

### 原因

MCP の tool 定義が **annotation（`readOnlyHint`、`destructiveHint` など）を持っておらず、Claude が「呼んで安全か」「呼ぶ価値があるか」を判定できない** 状態です。

もう一つよくあるのは、tool description が「Get portfolio」のように漠然としていて、Claude が「どの問いに対して呼ぶべきか」を判定できないケース。

### 対処

1. `fastmcp` の場合、tool の decorator に annotation を追加:
   ```python
   from mcp.types import ToolAnnotations

   @mcp.tool(
       annotations=ToolAnnotations(
           readOnlyHint=True,        # 副作用なし（読み取り専用）
           destructiveHint=False,    # 破壊的でない
       )
   )
   def get_portfolio() -> dict:
       """現在のポートフォリオのスナップショットを返す。
       
       ユーザーが資産状況、維持率、評価損益、為替リスクについて
       聞いてきた場合は、まずこの tool を呼んで最新データを取得すること。
       """
       ...
   ```
2. description 部分は「何を返すか」だけでなく **「どの質問に対してこの tool を呼ぶべきか」** まで書く。読み取り専用の tool では `readOnlyHint=True` が Claude に「呼んでも取り返しがつく」と伝える強いヒントになります
3. 再デプロイして Claude.ai 側で Connector を一度削除・再追加（tool 定義のキャッシュクリア）

`readOnlyHint` / `destructiveHint` の仕様の詳細は第 10 章（MCP プロトコルの内部構造）で扱います。

## この章の使い方

接続段階のエラーは「サーバーは健康か」「スキーマは正しいか」「AI への伝達は足りているか」の 3 階層に分けて見ます。

- 1-2 項 = スキーマと認証（機械的なズレ）
- 3, 6 項 = AI に伝える情報の不足（言語的なズレ）
- 4, 5 項 = サーバーと AI の間のプロトコルや容量の問題

第 II 部のエラー図鑑はこの章で終わりです。次の第 III 部からは、エラー対処ではなく **設計判断** の話に入ります。第 7 章は「個人の資産データを公開 URL で返してよいのか」という公開境界の立場決めから始めます。
