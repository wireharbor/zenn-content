---
title: "プラットフォーム移行ランブック"
free: false
---

第 12 章で他プラットフォームと比較しました。この章は、実際に **移行を決めたときに踏む手順** のランブックです。Render から別サービスへ移ることを例に、環境変数・依存関係・GitHub 連携・AI アプリ側の再登録・ロールバックまで順に書きます。

移行の原則は 1 つ。**既存サービスを止めずに新側を立て、両方動いている時間を作ってから切り替える**。本番に穴を開けないことを最優先にします。

## 0 日目: 移行前にやる準備

コードに触る前に揃えるもの。

### 棚卸し: 現在の Render の全設定を書き出す

Render dashboard から次を **テキストに書き写して** ローカルに残します。

- Service Name、Region
- Build Command（例: `pip install -r requirements.txt`）
- Start Command（例: `uvicorn main:app --host 0.0.0.0 --port $PORT`）
- Environment Variables の **キー名のリスト**（値はあとで個別に吸い出す）
- Instance Type（Free / Starter / Standard）
- Connected GitHub Repository と Branch
- Custom Domain が設定されていれば DNS レコード
- Cron Jobs / Background Workers があればそれぞれの設定

Render の `render.yaml` を持っているなら、それが棚卸しのほぼ正本になります。持っていない場合は dashboard の Settings 画面をスクリーンショットで撮っておきます。

### 環境変数の安全な移動

環境変数を新側に移すとき、値は **ターミナルの履歴に残さない** のが肝心です。

- Render dashboard で値をクリップボードにコピー → 新側の dashboard に直接ペースト
- ターミナルに `export KEY=xxx` などで貼らない（history に残る、ps で見える）
- 値を一度ローカルファイルに保存する場合、`.env` 系統のファイル名にして `.gitignore` 済みであることを先に確認

Google の credentials.json のような大きな JSON を環境変数で渡している場合、そのまま JSON 文字列をコピペで運びます。整形を挟むと崩れます。

### AI アプリ側で登録中の URL をメモ

以下を今の段階でメモしておきます。切り戻しのときに必要です。

- ChatGPT GPT Builder の Action で設定している `servers.url`
- Claude.ai Custom Connector の URL
- 外部 ping（UptimeRobot 等）の監視対象 URL

## 1 日目: 新側に並行でデプロイする

既存の Render は **そのまま動かし続けた状態** で、移行先に同じコードをデプロイします。

### GitHub に移行用ブランチを切る（任意）

**コードに変更がなければ不要** です。Render と移行先が同じ main ブランチを watch していてよい場合、コード側は何も触らず、新側で「このリポジトリを繋ぐ」だけで済みます。

ただしプラットフォーム固有のファイル（`railway.json`、`fly.toml`、`Dockerfile`、`vercel.json` など）を追加する必要があるときは、現在動いている main を壊さないよう `migration/xxx` のようなブランチで作業してから、検証が済んだら main に merge する順序にします。

### 新側でサービスを作成

Railway / fly.io / Vercel のダッシュボードで、新しい service を作って GitHub リポジトリを繋ぎます。

- **Railway**: New Project → Deploy from GitHub repo → リポジトリ選択。Build 自動、`PORT` 環境変数は勝手に渡る
- **fly.io**: `fly launch` で対話形式にリポジトリから `fly.toml` を生成。Dockerfile が無ければ `fly launch` が作成案を出す
- **Vercel**: Import Git Repository → Python project として検出、`vercel.json` で FastAPI の entry を指定

最初のデプロイはほぼ確実に失敗します（環境変数が未設定のため）。これは想定内です。

### 新側に環境変数を入れる

0 日目でメモしたキー名に従って、新側の dashboard で環境変数を登録します。

- 値は Render から直接コピーしてペースト
- secret を他のテキストファイルに書き出さない
- `.env` を commit していないことを再確認

入れ終わったら手動で再デプロイをトリガー。新側が起動すれば、そこから URL が発行されます。

### 新側の URL で動作確認

新側の URL（例: `https://your-service-new.up.railway.app/portfolio`）を叩き、次を確認:

1. `curl https://.../health` が 200
2. `curl https://.../portfolio` が JSON を返す
3. レスポンスの内容が Render 側と **完全に一致** するか（diff を取る）
4. OAuth / Bearer 認証が効くか（401 が返るべきパスで 401 が返り、認証ありで叩くと 200）

ここまで合えば、新側は Render と同じ動きをしています。ここまでを **移行の前半戦** として、次の切り替えに進みます。

## 2 日目: AI アプリ側を新側に切り替える

新側が安定して動くことを確認したら、AI アプリの参照先を新しい URL に差し替えます。ここが実質の「切り替え」のタイミングです。

### ChatGPT 側（GPT Builder）

1. https://chatgpt.com/gpts/editor で該当 GPT を開く
2. Configure タブ → Actions → 既存の Action を開く
3. Schema の `servers.url` を新側の URL に書き換え（例: `https://your-service-new.up.railway.app`）
4. Save
5. モバイルアプリから「今の維持率は？」と聞いて、新 URL を叩いて JSON が返ってくるか確認
6. ChatGPT Action の「Test」ボタンでも同時確認

### Claude.ai 側（Custom Connector）

Claude.ai の場合、Connector の URL を **直接編集する機能が無い** ことが多いので、旧 Connector を削除して新 Connector を追加する形になります。

1. Settings → Connectors → 既存の Connector を削除
2. 「+」から Add custom connector → 新側の MCP URL（例: `https://your-service-new.up.railway.app/mcp`）を入れて追加
3. モバイルアプリで Connector をオンにして「今の維持率は？」で動作確認

### 外部 ping / 監視

UptimeRobot などで旧 URL を監視していた設定を、新 URL に更新します。監視がなくなると新側のスリープに気付きません。

## 3 日目: 旧側を停止する

新側で数日間運用して事故が出ないのを確認したら、旧側を停止します。

1. Render dashboard で該当 Web Service を **Suspend**（停止）する
2. 1-2 週間置いて問題がないか見る。問題があったら Resume でロールバック可能
3. 完全に新側で定着したら、Render の Service を **Delete**

いきなり Delete しない理由は、ロールバック手段を確保するためです。Suspend 状態なら数クリックで戻せます。Delete すると環境変数も全部消えて、再構築には時間がかかります。

## ロールバック手順

移行後に問題が出たら、次の順で逆方向に戻します。

1. **Render を Resume**（停止中から再開）
2. AI アプリの Action / Connector の URL を旧 Render URL に戻す
3. 外部 ping の監視対象を旧 URL に戻す
4. 新側を停止（設定は残したまま）

**戻すのも 30 分以内で終わる** 設計になっているはずです。新側を立てたときの作業の逆を踏むだけだからです。

## よくある失敗と回避

### 失敗 1: Python バージョンが違って新側で SyntaxError

Render は `runtime.txt`、Railway は `nixpacks.toml`、fly.io は Dockerfile、Vercel は `package.json` や Function 設定で Python バージョンを決めます。**新側で同じバージョンを明示的に指定** します。デフォルトに任せると古いバージョンが選ばれることがあります。

### 失敗 2: `$PORT` の扱いが違う

Render、Railway、fly.io はすべて `$PORT` を環境変数で渡します。Start Command で `--port $PORT` を使っていれば互換です。Vercel は Serverless Function モデルなので `$PORT` は無く、エクスポートする関数の形式が違います。Vercel に移す場合は FastAPI アプリを Serverless 対応に書き換える必要があります。

### 失敗 3: 永続ディスクに書いていたファイルが消える

Render の Disks で書いていたファイルを移行先で書き続けるには、移行先でも Volume / Disk 機能を有効にし、既存ファイルを手動でコピーする必要があります。「スナップショットは Git で管理、永続ディスク不要」の設計にしておくと、この問題は消えます（`stateless_http=True` の話と同じ思想）。

### 失敗 4: AI アプリが新 URL を認識しない

GPT Builder の Action の schema を更新したのに、モバイルアプリから叩くと古い URL に行く場合、キャッシュが効いている可能性があります。Web の GPT Builder で「Update」ボタンを押して明示的に保存する、一度会話を新しく始める、アプリを再起動する、で解決します。

## 移行後の点検

切り替え完了後、次を 1 週間追います。

- 新側のログで 5xx が出ていないか
- AI アプリ側で「応答なし」「タイムアウト」が出ていないか
- 想定通り速くなっているか（cold start が短くなった、など移行の目的を再確認）
- 月次の請求額が想定内か

数字で確認できる期間を置いてから、旧側を Delete します。

---

第 V 部はここで終わりです。次の第 VI 部（第 14-16 章）は、プラットフォームが変わっても付きまとう **データ設計** の話に移ります。データの新鮮さ、履歴の持ち方、差分の取り方、この 3 つを個人運用で落としどころのあるレベルにする話です。
