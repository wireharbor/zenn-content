---
title: "fastmcp を使うか手書きするか"
free: false
---

第 10 章で MCP の内部構造を一通り見ました。この章は、それを実装する手段として **fastmcp を使うか、FastAPI で手書きするか** の選択を扱います。

先に結論: 個人用途のほとんどで fastmcp が正解です。ただし「MCP と REST を同じアプリに同居させる」「OAuth を独自に持つ」「プラットフォームごとにレスポンスを後処理する」の 3 つが絡むと手書きの比重が増えていきます。筆者のサーバーはその 3 つ全部に当たっていて、結果として **fastmcp + FastAPI の混成** になっています。

## fastmcp で書くと何が楽か

Anthropic 製の `fastmcp`（正式名 `mcp.server.fastmcp.FastMCP`）は、MCP サーバーをデコレータベースで書けるライブラリです。最小構成はこれで動きます。

```python
from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations

mcp = FastMCP("My Portfolio", stateless_http=True)

@mcp.tool(
    annotations=ToolAnnotations(readOnlyHint=True, idempotentHint=True)
)
def get_portfolio() -> dict:
    """現在のポートフォリオのスナップショット。"""
    return {"maintenance_rate": 0.82, "leverage": 5.5}

if __name__ == "__main__":
    mcp.run(transport="streamable-http", host="0.0.0.0", port=8000)
```

これだけで `/mcp` エンドポイントが立ち上がり、Claude.ai の Custom Connector から叩けます。fastmcp が面倒を見てくれる領域:

- **Streamable HTTP / SSE / stdio の transport 実装**
- **JSON-RPC 2.0 のリクエスト・レスポンス処理**（`tools/list`、`tools/call`、`resources/list` 等のメソッド）
- **tool の引数 / 戻り値の JSON Schema 自動生成**（Python の型注釈から変換）
- **`CallToolResult` の型安全な構築**（`content[]` と `structuredContent` の整合）
- **tool annotation / resource URI / prompt** のすべての仕様

自分で書くと、ここだけで数百行になります。しかも MCP 仕様は進化中で、SSE から Streamable HTTP への移行のような変更が時々入るため、ライブラリに任せておくほうが仕様追従の手間が消えます。

## fastmcp だけでは届かない領域

次のようなケースは、fastmcp の外側（FastAPI 側）に書く必要が出ます。

### 1. MCP と REST を同じアプリで同居させたい

ChatGPT の GPT Builder は OpenAPI スキーマを介して **REST API** を叩きます。Claude.ai の Custom Connector は **MCP** を叩きます。両方に繋ぎたいと、同じサーバー内に `/portfolio`（REST）と `/mcp`（MCP）が同居する構成になります。

fastmcp の `mcp.run()` は MCP 専用の ASGI アプリを立てるので、そこに REST エンドポイントを後から足すのは不自然です。代わりに、**FastAPI をメインにして fastmcp の ASGI アプリを mount する** 形が綺麗です。

```python
from fastapi import FastAPI
from mcp.server.fastmcp import FastMCP

app = FastAPI()
mcp = FastMCP("My Portfolio", stateless_http=True)

# fastmcp の streamable HTTP アプリを /mcp にマウント
app.mount("/mcp", mcp.streamable_http_app())

# REST のエンドポイントは FastAPI で普通に書く
@app.get("/portfolio")
async def get_portfolio_rest():
    return {"maintenance_rate": 0.82, "leverage": 5.5}
```

`/mcp` に来たリクエストは fastmcp が処理し、`/portfolio` は FastAPI が処理します。共通のビジネスロジック（スプレッドシートを読む、計算する）は別関数にして両方から呼べば、同じデータを 1 箇所で管理できます。

### 2. OAuth を自分のエンドポイントで持ちたい

Claude.ai が Custom Connector を登録するときに OAuth フローを通ります。`/authorize`、`/token`、`/register` のエンドポイントをサーバー側が提供する必要があります。

fastmcp には OAuth ヘルパーが入りつつありますが、**承認 UI を日本語で自分色にカスタマイズする** とか、**セッションを stateless にして JWT で自分で署名する** といった踏み込んだ実装は手書きになります。FastAPI に `/authorize` を書いて、HTML テンプレートで承認画面を自前用意、`/token` で PyJWT で署名し直す、のような形です。

### 3. レスポンスをプラットフォーム別に後処理したい

ChatGPT と Claude.ai で structuredContent の特別キーの扱いが違う話は第 10 章で触れました。fastmcp の tool デコレータは「最終的な `CallToolResult` を返す」までが役割で、「**どのクライアントに対してどう整形するか**」の分岐は含まれません。

分岐を挟みたい場合、tool 関数の中で自分でクライアント判定して分岐するか、fastmcp より外側（ASGI middleware レイヤー）でレスポンスを加工します。筆者は前者を採用していて、tool 関数の最後に ChatGPT 用 / Claude 用の finalize 関数を呼ぶ形で実装しています。

### 4. ASGI middleware レベルの細工をしたい

第 10 章の「Accept ヘッダーの落とし穴」のように、**リクエスト内容をサーバー受付直後に書き換える** 処理は、fastmcp より下の ASGI 層に入れる必要があります。FastAPI 側の middleware / Starlette Mount で書きます。

## 手書きに全部倒す選択肢はあるか

fastmcp を使わず、JSON-RPC 2.0 のハンドラを FastAPI にゼロから書くこともできます。`POST /mcp` を FastAPI に書いて、body の `method` を見て `tools/list` / `tools/call` / `resources/list` を自分で分岐する形。

この選択肢が合う場面:

- MCP の仕様を隅々まで理解したい学習目的
- fastmcp が塞いでいる内部に手を入れたい（特殊な transport 対応、バージョン並列サポート等）
- ライブラリに依存したくない（long-term 依存を避けたい）

実運用目的でこの道を取る理由は少ないです。仕様追従のコストが重く、Anthropic 側の変更に追いつくためだけに定期的な書き直しが必要になります。

## 筆者の設計: fastmcp + FastAPI の混成

筆者のサーバーは 3 つの「ハマりどころ」が全部当たっているため、混成になっています。

- **データ取得の MCP tool**: fastmcp の `@mcp.tool()` で書く（5 個）
- **データ取得の REST API**: FastAPI の `@app.get()` で書く（REST 同居）
- **共通ロジック**: `build_snapshot_payload()` のような普通の Python 関数にして、MCP tool と REST ハンドラの両方から呼ぶ
- **HTML ダッシュボード**: FastAPI で `/dashboard` を書き、テンプレートから HTML を返す
- **OAuth**: FastAPI に `/authorize` / `/token` / `/register` を手書き
- **Accept ヘッダー補正**: FastAPI の middleware で書く
- **プラットフォーム別の finalize**: tool 関数の最後に `finalize_for_*()` を呼ぶ

結果として、fastmcp は「MCP サーバーの仕様部分だけ」を引き受け、その外側の運用要件は FastAPI で書いています。どちらかに倒さず、境界をはっきり分けて混成する形です。

## 判断のための 4 問

自分で書くときにどの構成を取るか、次の 4 問で絞れます。

1. **ChatGPT と Claude.ai の両方に繋ぐか** — 両方繋ぐなら MCP と REST の同居が必要。FastAPI + fastmcp mount
2. **OAuth が必要か** — Claude.ai の Custom Connector は OAuth 前提。手書きか、fastmcp の OAuth ヘルパーか
3. **プラットフォーム別に返すキーを変えたいか** — 変えたいなら finalize 関数を挟む余地が要る
4. **HTML ダッシュボードや管理画面も同じアプリに入れたいか** — 入れるなら FastAPI メイン構造

多くの個人プロジェクトで Q1 の答えが「Claude.ai だけ」なら、fastmcp 単体で綺麗に収まります。Q1 が「両方」になった瞬間、混成構成が現実的になります。

## 最初に選ぶなら

**fastmcp で書き始める。** これが先の答えです。

- MCP 仕様を自力で追う手間が要らない
- Python の型注釈だけで JSON Schema が埋まる
- annotation / resource / prompt の仕様を間違えにくい
- 将来、仕様の更新が入っても自分で追う必要がない

書き始めて「REST も要る」「OAuth も要る」となったら、FastAPI をメインにして fastmcp を mount する形に切り替えればよい。この順番なら、最初から FastAPI で手書きする場合より迷いが少なく、動くところまで速く着けます。

次の第 V 部（第 12-13 章）は、これまで Render を前提に書いてきたクラウド側を **他のプラットフォーム（Railway / fly.io / Vercel）と比較** して、必要になったときに移行するランブックを書きます。
