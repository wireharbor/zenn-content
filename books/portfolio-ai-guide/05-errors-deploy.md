---
title: "エラー図鑑（3）デプロイ編"
free: false
---

この章では、ローカルで動くようになった FastAPI を Render などのクラウドに上げる段階で出る 6 種のエラーを扱います。

ローカルは動くのにクラウドで落ちる、というのはほぼ **環境の差** が原因です。Python のバージョン、インストール済みライブラリ、環境変数、バインドするホスト・ポート、ブランチ設定。差分が出やすい場所を順に挙げていきます。

この章の例は Render を前提にしますが、Railway / fly.io / Vercel でも症状と対処の構造はほぼ同じです。プラットフォーム間の差は第 12 章（プラットフォーム比較）で扱います。

## 1. 朝イチのアクセスが 30-60 秒かかる（Render の無料枠スリープ）

### 症状

デプロイは成功していて、昨日まで普通に動いていた。朝 ChatGPT から「今の維持率は？」と聞くと「Runtime error」や「応答がありません」が返る。もう一度聞くと今度は普通に返ってくる。

Render の Logs を見ると、失敗したタイミングで `Starting service...` のログが出ています。

### 原因

Render の無料枠（Free tier）は **15 分アクセスがないとインスタンスをスリープさせる** 仕様です。スリープしたインスタンスは次のアクセスで起こされますが、起動完了まで 30-60 秒かかります。

GPT Builder の Action や Claude.ai の Custom Connector はおおむね 30 秒でタイムアウトするため、スリープからの起き上がりを待てずに失敗します。

### 対処

運用方針で 3 択あります。

1. **外部から定期 ping**: UptimeRobot など無料の監視サービスで `/portfolio` や `/health` を 5-10 分間隔で叩いてスリープさせない。厳密には Render の利用規約で Keep-alive を禁じている時期もあったので、最新規約を確認してから使う
2. **有料プランに上げる**: Render Starter（月 7 ドル程度）でスリープを無効化。毎日使うなら費用対効果は悪くない
3. **別プラットフォームに移す**: Railway の Hobby（月 5 ドル）はスリープなし。fly.io や Vercel も選択肢（比較は第 12 章）

筆者は外部 ping 方式を採りつつ、使用頻度が上がった時点で Railway Hobby に載せ替えて安定化しました。

## 2. `502 Bad Gateway` / `Service Unavailable`（PORT / ホスト指定ミス）

### 症状

Render の build は緑の ✓ で成功している。デプロイ完了直後、`https://〇〇.onrender.com/portfolio` にアクセスすると `502 Bad Gateway` または `Service Unavailable` が出る。Logs には `Your service is live 🎉` のメッセージが出ているのに繋がらない。

### 原因

Start Command が `uvicorn main:app` のままで、**ホストとポートの指定が抜けている** 状態です。

```
uvicorn main:app                     ← ローカル用。クラウドでは繋がらない
uvicorn main:app --host 0.0.0.0 --port $PORT   ← Render で使う形
```

Render はコンテナに毎回違うポート番号を `$PORT` 環境変数で渡します。`--port $PORT` が無いと uvicorn は既定の 8000 で待ち受けますが、Render が外部から叩くのは別のポート（例 10000）なので、行き先が合わずに 502 になります。

`--host 0.0.0.0` も同じ理屈で、既定の `127.0.0.1` のままだとコンテナの外から繋がりません。

### 対処

Render dashboard の Settings → Build & Deploy → Start Command を以下に変更:

```
uvicorn main:app --host 0.0.0.0 --port $PORT
```

保存して **Manual Deploy** を走らせると新しいコマンドで再起動されます。次のアクセスで 502 が消えているはずです。

## 3. 環境変数が undefined で機能が死ぬ

### 症状

デプロイは成功し、`/portfolio` も空データで 200 を返す。ただし GPT から聞いても「データが空です」と言う。Logs を見ると `credentials.json: None` や `SHEET_ID: ''` のようなログが出ている。

### 原因

Render dashboard の **Environment Variables** に必要な値が登録されていません。ローカルでは `.env` ファイルから読めていたが、`.env` は（後述のとおり）リポジトリに commit していないため、Render には届いていない状態です。

### 対処

1. Render dashboard → Settings → **Environment Variables** を開く
2. `.env` に書いているキーを 1 つずつ Render 側に登録する
   - `SHEET_ID`: 対象スプレッドシートの ID
   - `GOOGLE_CREDENTIALS_JSON`: credentials.json の中身を丸ごと貼る（ファイルパスでなく文字列として）
   - その他 API キー、Bearer トークン類
3. Save → Deploy が自動で走る
4. Logs で値が読めているか確認

`GOOGLE_CREDENTIALS_JSON` のように大きな JSON 文字列を環境変数で渡すときは、スクリプト側も `os.getenv("GOOGLE_CREDENTIALS_JSON")` を JSON にパースして使う書き方に変える必要があります。エージェントに「Render の環境変数で渡す前提に書き換えて」と頼むのが速いです。

## 4. `ModuleNotFoundError` だが手元では動く（requirements.txt 漏れ）

### 症状

手元では `uvicorn main:app` で問題なく動く。Render にデプロイすると Build は通るが、起動時に:

```
ModuleNotFoundError: No module named 'gspread'
```

または

```
ImportError: cannot import name 'BaseModel' from 'pydantic'
```

### 原因

**requirements.txt に必要なライブラリが列挙されていない**、あるいは **バージョンが固定されていなくて Render 側で別バージョンが解決された** のが典型です。

手元は開発を重ねるうちに `pip install` で色々入っていて、スクリプトがそれを前提にしているが、クラウドは requirements.txt に書いてあるものしか入れません。

### 対処

1. ローカルの仮想環境で `pip freeze > requirements.txt` を実行し、使っているライブラリ全部をバージョン付きで書き出す
2. 出力された requirements.txt を確認し、`fastapi`、`uvicorn`、`gspread`、`google-auth` など、スクリプトが `import` しているものが全部入っているかチェック
3. commit して push。Render の auto-deploy が走って再ビルドされる

毎回 freeze すると無関係なライブラリ（開発ツール等）まで入り、ビルド時間が伸びます。慣れてきたら手で必要な分だけをバージョン付きで書くほうが綺麗です。

```
fastapi==0.110.0
uvicorn[standard]==0.27.0
gspread==5.12.0
google-auth==2.28.0
```

## 5. Python のバージョンがクラウドと手元で違う

### 症状

ローカルでは動くコード（例えば `match/case` や `|` によるユニオン型）が、Render のビルドログで SyntaxError になる。

```
SyntaxError: invalid syntax  (at the match statement)
```

### 原因

Render が使う Python のバージョンがデフォルトだと古い（執筆時点で 3.7）、または手元と違うバージョンが選ばれています。`.python-version` ファイル（pyenv で使うやつ）は **Render が読まない** のが落とし穴です。

### 対処

リポジトリのルートに `runtime.txt` というファイルを作り、中身にバージョンを 1 行だけ書きます:

```
python-3.12.2
```

commit して push すると、次のビルドからこのバージョンで起動します。手元と同じバージョンを指定するのが無難です。

`.python-version` を残してもエラーにはなりません（Render が無視するだけ）。pyenv ユーザーは両方置いて揃えておきます。

## 6. credentials.json を誤ってリポジトリに commit した

### 症状

`git push` のあと、**GitHub から「Exposed secret detected」警告メール** が届く、または GitHub の UI に赤いバナーが出る。検索用の bot が公開リポジトリをスキャンして鍵流出を検知した合図です。

検知されなくても、公開リポジトリに `credentials.json` や `.env` が混ざっているのを後から自分で気づくケースもあります。

### 原因

`.gitignore` に `credentials.json` や `.env` を入れずに `git add .` してしまった、というのが最多パターンです。

### 対処

**見つけたら即、鍵を無効化することから始めます。** コミット履歴から消しても、それを読み取った攻撃者は鍵を持ったままなので、鍵自体を使えなくするのが最優先です。

1. Google Cloud Console → サービスアカウント → キータブ → 該当の鍵を **削除**（Revoke）
2. 同じアカウントで新しい鍵を発行してダウンロード
3. ローカルの `.gitignore` に `credentials.json`、`.env`、`*.key` を追加して commit
4. 新しい credentials.json を Render の環境変数（第 3 項で触れた方法）に貼り直す
5. リポジトリが公開の場合は、履歴から該当ファイルを消すために `git filter-repo` を使うか、最悪リポジトリを作り直す

クラウドに上げる前の **1 回目の push 前** に `.gitignore` を整えておくのが唯一の予防策です。

```
# .gitignore の最低ライン
.env
.env.*
credentials.json
*.pem
*.key
__pycache__/
.venv/
```

このファイルを最初の commit より前に置いておけば、多くの事故を未然に防げます。

## この章の使い方

デプロイ段階のエラーは「ローカルで動くのにクラウドで動かない」という形で出るので、差分を疑うのが最短です。Python バージョン、requirements.txt、環境変数、ホスト・ポート、この 4 つがズレの大半です。

次の章（第 6 章）は、デプロイに成功してクラウドから URL が返るようになった後、**GPT Builder / Claude.ai の接続段階** で出るエラーを扱います。OpenAPI スキーマと実レスポンスのズレ、MCP で tool が認識されない、レスポンスが token limit で切れる、といったパターンが中心になります。
