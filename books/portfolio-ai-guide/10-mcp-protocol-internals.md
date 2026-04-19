---
title: "MCP プロトコルの内部構造"
free: false
---

第 6 章で Claude.ai の Custom Connector が「Connected, 0 tools」と言う問題や、tool annotation 漏れで Claude が呼んでくれない問題に触れました。この章は、その背景にある **MCP（Model Context Protocol）の内部構造** を、自分で拡張・デバッグするために必要な粒度まで踏み込みます。

対象は連載 Step 4b まで通して、自分の MCP サーバーを一度は動かした読者です。OpenAPI との対比で「MCP で何が増えたのか、どう違うのか」を整理します。

## MCP と OpenAPI の関係

OpenAPI は「この URL に何を送るとこういう JSON が返る」というフォーマットです。ChatGPT の GPT Builder は OpenAPI スキーマを読んで直接 HTTP API を叩きます。

MCP は Anthropic が提唱した、AI と外部リソースをつなぐための **AI 向けプロトコル** です。単なる HTTP API ではなく、「これは読み取り専用の tool です」「これは参照可能な資料です」といった **AI 向けのメタ情報** を一緒に運ぶ構造になっています。

| 項目 | OpenAPI | MCP |
| --- | --- | --- |
| 意図 | HTTP API を機械的に記述する | AI に対してリソースを提供する |
| 識別子 | `operationId` | `tool name`（+ annotations） |
| レスポンス | JSON そのまま | `content[]` / `structuredContent` / `resources` |
| 呼ぶ側 | 任意の HTTP クライアント | MCP client（Claude / Claude Desktop / Cline 等） |
| 想定 | 広いエコシステム、人が読むドキュメント | AI の判断支援、機械のみが読む |

同じ「ポートフォリオを返す」というタスクに対して、OpenAPI は「GET /portfolio が Portfolio オブジェクトを返す」と書くのに対し、MCP は「`get_portfolio` という **読み取り専用** で **副作用のない** tool が存在する」と書きます。後者のほうが AI への伝わり方が強いわけです。

GPT Builder（ChatGPT）は OpenAPI スキーマで繋ぐ。Claude.ai の Custom Connector は MCP で繋ぐ。同じ API に両方繋げたい場合、両方の口を同じアプリに持たせることになります。

## MCP サーバーの 3 つの構成要素

MCP サーバーが AI に提供できるものは 3 種類あります。

### Tool

AI が呼び出せる関数です。Python の関数に `@mcp.tool()` デコレータを付ければ tool になります。引数と戻り値は JSON Schema で型付けされます。筆者の場合は「ダッシュボードを描画する tool」「ニュースドライバーを返す tool」といった具合に、用途別に数本を定義しています。

tool は基本的に毎回 AI が判断して呼びます。「呼ぶべきか」を AI に判断させるために、**名前、description、annotation** が効いてきます（後述）。

### Resource

AI が「URI で参照する」コンテンツです。`portfolio://snapshot/raw` のような URI で、AI は tool 呼び出しを介さず直接取りに行けます。マニュアルや静的な設定ファイル、ドキュメント類を置くのに向いています。

現実には Resource を使わず tool で全部返す設計のほうが多数派です。MCP client 側の Resource 対応状況にばらつきがあり、tool は確実に動くためです。本書の範囲では Resource は使わず、必要ならすべて tool 経由で返す形にしています。

### Prompt

サーバー側が用意した **会話テンプレート** です。AI 側から「このプロンプトを挿入してください」と指示できる仕組み。現実にはあまり使われず、本書の設計でも採用していません。

### まとめ

自分の MCP サーバーで最初に書くのは Tool だけで十分です。Resource と Prompt は必要になってから足します。

## Transport の 3 種類と Streamable HTTP の現在地

MCP クライアント（Claude.ai 等）とサーバーを繋ぐ経路は 3 つあります。

### stdio（標準入出力）

ローカルで Claude Desktop のようなデスクトップアプリと繋ぐときに使います。Claude Desktop の設定ファイルに「このコマンドを起動する」と書くと、アプリが起動時にサブプロセスとして MCP サーバーを立ち上げ、stdin / stdout でメッセージをやり取りします。

外に公開する用途には使えません（HTTP で叩けないため）。

### SSE（Server-Sent Events）

初期の MCP サーバーがクラウドから繋ぐときに使っていた方式です。HTTP 長時間接続で `text/event-stream` を流し続ける形。現在は **非推奨** で、新規の MCP サーバーは Streamable HTTP に寄せるのが規定路線です。

### Streamable HTTP（現行）

HTTP POST でリクエストを受け、レスポンスを **状況に応じて JSON またはストリームで返す** 方式です。短時間の tool 呼び出しは JSON 1 回で返す。長時間の処理や progress 通知が要るときは SSE ストリームに切り替える。クライアント側は両方を受け取れるよう `Accept: application/json, text/event-stream` を送ります。

Claude.ai の Custom Connector、Anthropic の公式 MCP SDK（`fastmcp`）、最近の MCP client は Streamable HTTP を前提にしています。本書の読者が自作するなら Streamable HTTP で書いておくのが将来も楽です。

### Accept ヘッダーの落とし穴

Streamable HTTP で 406 エラーが出るケースの多くは、クライアントが **`Accept: application/json, text/event-stream` を送っていない** ことが原因です。仕様準拠のクライアントは送りますが、一部のツール（古い Codex、curl テストなど）は送らないことがあります。

対処は 2 つ。

- クライアント側を修正する（可能ならこちら）
- サーバー側のミドルウェアで Accept ヘッダーを補完する

後者は FastAPI の middleware で `request.scope["headers"]` に `(b"accept", b"application/json, text/event-stream")` を追加するだけです。「Accept ヘッダー補正 middleware」として別クラスに切り出しておくとデバッグ時に追いやすくなります。デバッグ時に「ブラウザからは叩けないが curl からは叩ける」的な挙動に出くわしたら、Accept ヘッダーを疑ってください。

## `stateless_http=True` の意味

fastmcp でサーバーを組むとき、`FastMCP(..., stateless_http=True)` という指定があります。これは **セッション状態をサーバー側に保持しない** モードです。

- デフォルト（`stateless_http=False`）: クライアントごとに session ID を発行し、サーバーがメモリに状態を持つ。Render のインスタンスが再起動すると session が切れて、クライアントが再接続する必要がある
- `stateless_http=True`: session を持たず、リクエストごとに自己完結。Render が寝ても再起動しても session が切れないので、クライアント側の体感が安定する

トレードオフとして、session 間で状態を持ち越したい機能（長時間のストリーミング処理、会話を跨いだキャッシュ）は使いにくくなります。ポートフォリオを JSON で返すだけの個人向け用途ならまず `stateless_http=True` で始めて、必要になってから外すのが実用的です。

Render のような無料枠でスリープが前提のプラットフォームでは、stateless のほうが圧倒的に事故が少ないです。

## Tool annotation の 4 種類

MCP の仕様には、tool に付けられる 4 種の annotation があります。AI が「この tool を呼ぶべきか、呼んで安全か」を判断するための機械可読ヒントです。

| annotation | 意味 | 代表的な用途 |
| --- | --- | --- |
| `readOnlyHint` | この tool は外部状態を変更しない | データ取得系 tool には true |
| `destructiveHint` | この tool は取り返しのつかない変更をする | 削除・送信系 tool には true |
| `idempotentHint` | 同じ引数で何度呼んでも結果が同じ | キャッシュ可能性の判定 |
| `openWorldHint` | 外部の世界（Web、他システム）にアクセスする | Web 検索 tool には true |

ポートフォリオ取得 tool なら `readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False` の組み合わせになります（自分のサーバー内のデータを読むだけで、呼ぶたびに副作用が起きないため）。

これらをちゃんと付けておくと、Claude は:

- 呼ぶ前の確認 prompt を省略する（readOnly なので）
- 一度呼んだ結果を会話内でキャッシュ的に扱う（idempotent なので）
- Web 検索と混同しない（openWorld=false なので）

といった適切な振る舞いをします。付いていないと保守的に動き、毎回確認 prompt が入ったり、呼ぶべき場面で呼ばなかったりします。

fastmcp での書き方:

```python
from mcp.types import ToolAnnotations

@mcp.tool(
    annotations=ToolAnnotations(
        readOnlyHint=True,
        destructiveHint=False,
        idempotentHint=True,
        openWorldHint=False,
    )
)
def get_portfolio() -> dict:
    """現在のポートフォリオ状態を返す。

    ユーザーが資産状況・維持率・損益について聞いたときに呼ぶ。
    """
    ...
```

## structuredContent の構造

MCP の tool 応答は `content[]` と `structuredContent` の 2 系統があります。

- `content[]`: テキスト / 画像 / リソースリンクなどを並べたリスト。ユーザーに見せる表示内容
- `structuredContent`: AI が読む構造化データ。辞書（JSON オブジェクト）

同じ情報を両方に入れる設計もあれば、structuredContent にだけ入れて AI に解釈させ、content[] は空にする設計もあります。筆者のサーバーでは、AI 側に構造化された形で渡したいデータは全部 `structuredContent` に載せて、`content[]` は軽い要約テキストだけにする形を採っています。

structuredContent のキー名は自由ですが、**プラットフォームごとに特別な意味を持つキー** が存在します。後述します。

## サイズの壁: ChatGPT の 45KB、Claude の実効 token 限度

tool 応答のサイズには事実上の上限があります。

### ChatGPT Action（GPT Builder 経由）

実測で **約 45KB 前後が上限** です。45KB を超えると `ResponseTooLargeError` が返ってきて、AI は応答を読めずに失敗します。公式ドキュメントには閾値が明記されていないため、curl と `wc -c` で手計測して 40KB 前後に収める運用が必要です。

```
curl -s https://〇〇.onrender.com/portfolio | wc -c
```

### Claude.ai（MCP 経由）

`ResponseTooLargeError` 的な明示的エラーはありませんが、**tool 応答のサイズが大きいと Claude の回答が浅くなる** 現象が起きます。ざっくりの体感で、structuredContent が 20,000 トークン（= 日本語で約 40,000 字）を超えると、Claude は要約に失敗するか、重要な項目を落としはじめます。

同じ tool で両方のプラットフォームに返す場合、ChatGPT 側の 45KB を上限に置けば Claude 側も楽です。

### サイズを抑える手段

- **軽量版 tool を別に作る**: `get_summary`（集計値だけ）と `get_full`（全データ）を分けて、AI が summary を先に呼ぶ設計にする
- **プラットフォーム別にキーを絞る**: ChatGPT 向けにはこれを残す、Claude 向けには別キーを残す、という構成を finalize 関数でやる
- **事前計算でレスポンスを短くする**: 銘柄ごとに計算させるのではなく、集計結果をスナップショットに保存しておき、MCP は参照するだけにする

筆者は 3 つ目を採用していて、日次でスナップショット用の Markdown / JSON を更新しておき、MCP tool はそれを読むだけにしています。tool 呼び出しは 100ms 以内で完了します。

## プラットフォームごとに挙動が違うキー

structuredContent の特定キーが、プラットフォームによって特別に解釈される挙動があります。

- `_html` キー: ChatGPT は MCP Apps widget として iframe で静的表示する。Claude.ai は自動で iframe 150px を表示し、モデルの自発的 artifact 描画が抑制される
- `artifact_rendering`: Claude 固有。Artifact パネルに描画すべきコンテンツのメタ指示
- `suggested_reply`: プラットフォームによって採用率が違う

結論として、**同じ structuredContent を両方のプラットフォームにそのまま返すと片方で壊れる** ことが起き、プラットフォーム別の finalize 関数で後処理することになります。筆者の構成では ChatGPT 用 / Claude 用の finalize 関数を分けて、ChatGPT 側には `_html` を注入、Claude 側からは `_html` を除去し artifact 指示を prepend する実装になっています。

この分岐設計の詳細と、新しいキーを追加するときの管理ルールは次の第 11 章（fastmcp を使うか手書きするか）で実装に寄せて書きます。

## この章の要点

- **MCP は HTTP API に AI 向けメタ情報を足したプロトコル**。OpenAPI と対立するのではなく、用途が違う
- **現行の transport は Streamable HTTP**。Accept ヘッダーが合わないと 406 で落ちる
- **`stateless_http=True`** は個人運用とクラウドスリープの両方で効く
- **tool annotation** は Claude の振る舞いを大きく変える。4 種を明示しておく
- **structuredContent** が AI 向けデータの主戦場。サイズ上限はある（ChatGPT 45KB）
- **プラットフォーム別に特別キー**があり、片方で通るものが片方で壊れる。finalize を分ける

次の第 11 章は、同じ MCP サーバーを **fastmcp で書くか、FastAPI で手書きするか** の選択を扱います。fastmcp のブラックボックスを避けるために手書きすべき場面がどこなのかを実装の差から示します。
