---
title: "エラー図鑑（1）インストール編"
free: true
---

この章では、連載 Step 1（AIエージェントのインストール）と Step 2（Python とライブラリのセットアップ）の範囲で、実際に詰まりやすい 7 種のエラーを扱います。

各エラーは **症状 → 原因 → 対処** の順で並べています。ターミナルに出たエラー文のキーワード（例: `ModuleNotFoundError`、`403`、`credentials.json`）で目次を引いて、該当節に飛んでください。

## 1. `'python' は、内部コマンドまたは外部コマンド...として認識されません`

### 症状

Windows の PowerShell またはコマンドプロンプトで `python main.py` を実行すると次が出る:

```
'python' は、内部コマンドまたは外部コマンド、
実行可能なプログラム、またはバッチファイルとして認識されません。
```

Mac の場合は `command not found: python` が出ます。

### 原因

Python インストーラーの最初の画面にある「Add Python to PATH」のチェックボックスにチェックを入れずに「Install Now」を押した、という Windows ではお決まりの落とし穴です。

Python 本体はインストールされていますが、ターミナルから `python` というコマンドで呼び出せる設定になっていません。

### 対処

一番確実なのは入れ直しです。

1. 設定 → アプリ → インストールされているアプリから Python を探してアンインストール
2. https://www.python.org/downloads/ から同じバージョンのインストーラーを再ダウンロード
3. 起動直後の画面で **「Add Python to PATH」に必ずチェックを入れる**（ここが全て）
4. 「Install Now」を押して完了
5. PowerShell を開き直し（既に開いているターミナルには変更が反映されないため）、`python --version` が通ることを確認

Mac の場合は Homebrew（`brew install python`）で入れ直すのが速いです。

## 2. `ModuleNotFoundError: No module named 'gspread'`

### 症状

```
python main.py
Traceback (most recent call last):
  File "main.py", line 1, in <module>
    import gspread
ModuleNotFoundError: No module named 'gspread'
```

gspread の部分は `google.auth`、`fastapi`、`uvicorn` など別のライブラリ名になることもあります。

### 原因

スクリプトが使っているライブラリを `pip install` していません。Python 本体には入っておらず、個別にインストールが必要なライブラリが多いためです。

### 対処

メッセージに出たライブラリ名を `pip install` します。

```
pip install gspread google-auth
```

FastAPI 側なら `pip install fastapi uvicorn`、MCP 側なら `pip install fastmcp` のように、用途ごとに必要なものを足します。

エージェント（Claude Code / Codex）に「このエラーが出た」と貼り付けて、必要な `pip install` コマンドを列挙してもらうのが最も速いです。

## 3. `FileNotFoundError: credentials.json`

### 症状

```
FileNotFoundError: [Errno 2] No such file or directory: 'credentials.json'
```

### 原因

Google スプレッドシートにアクセスするためのサービスアカウント鍵ファイル（`credentials.json`）が、スクリプトから参照できる場所に置かれていません。

スクリプトがカレントディレクトリからの相対パスで `credentials.json` を探す書き方になっていることが多く、ターミナルで違うフォルダから実行すると見つからないケースもあります。

### 対処

1. Google Cloud Console にログインし、対象プロジェクトの **IAM と管理 → サービスアカウント** を開く
2. 使っているサービスアカウントを選び、**キー** タブから新しい鍵（JSON）を作成してダウンロード
3. ダウンロードされた JSON を `credentials.json` にリネームし、`main.py` と同じフォルダに置く
4. ターミナルでスクリプトと同じフォルダに `cd` してから `python main.py` を実行

鍵ファイルを別フォルダに置いておきたい場合は、スクリプト内で絶対パスを使います（例: `gspread.service_account(filename="/Users/xxx/keys/credentials.json")`）。

## 4. `HttpError 403: Google Sheets API has not been used... before or it is disabled`

### 症状

```
googleapiclient.errors.HttpError: <HttpError 403 when requesting
https://sheets.googleapis.com/... returned
"Google Sheets API has not been used in project NNNNN before
or it is disabled.">
```

### 原因

Google Cloud プロジェクト側で **Google Sheets API** が有効になっていません。サービスアカウントを作っただけでは Sheets を叩く権限が付与されていない、という状態です。

### 対処

1. Google Cloud Console の検索バーに「Google Sheets API」と入力
2. API ライブラリのページが開くので「有効にする」を押す
3. 数秒待ってから再度 `python main.py` を実行

Google Drive API（ファイル一覧の取得に使う）も同時に必要になるケースが多いので、併せて有効化しておくと詰まりが減ります。

## 5. `gspread.exceptions.APIError: The caller does not have permission`

### 症状

```
gspread.exceptions.APIError:
{'code': 403, 'message': 'The caller does not have permission',
 'status': 'PERMISSION_DENIED'}
```

### 原因

API は有効化されている（4 は解決済み）が、**対象のスプレッドシート自体にサービスアカウントの閲覧権限が無い** 状態です。

サービスアカウントは Google Cloud 上のアカウントで、普通の Google アカウントとは別物扱いされます。スプレッドシートの共有先に個別に追加しないとアクセスできません。

### 対処

1. Google Cloud Console でサービスアカウントのメールアドレスをコピーする（`portfolio-reader@your-project.iam.gserviceaccount.com` のような形）
2. 対象のスプレッドシートをブラウザで開き、右上の **「共有」** をクリック
3. コピーしたサービスアカウントのメールを貼り付け、権限を **「閲覧者」以上** にして「送信」を押す（通知メールは送らなくても可）
4. 再度 `python main.py` を実行

複数のスプレッドシートを読みたい場合は、それぞれで同じ共有設定が必要です。

## 6. Claude Code / Codex の Local プロジェクトで Git が見つからない（Windows）

### 症状

Claude Desktop の Code タブでプロジェクトフォルダを指定したときに、Git に関するエラーが出てプロジェクトが開けない。

### 原因

Windows 版の Claude Code / Codex は Local モードで動くときに Git を前提としています。Mac は標準で Git が入っているため発生しませんが、Windows はデフォルトでは入っていません。

### 対処

1. https://git-scm.com/downloads/win から Git for Windows のインストーラーをダウンロード
2. 既定設定のままインストールを完了（エディタ選択など途中の画面は触らず「Next」で進んでよい）
3. Claude Desktop / Codex を一度終了して起動し直す
4. Code タブでもう一度プロジェクトフォルダを指定

Git をコマンドで使うかどうかは関係なく、このシリーズの範囲では「入れておくだけでよい」ものとして扱って構いません。

## 7. Claude Desktop で指示してもファイルが作られない（Chat タブ問題）

### 症状

Claude Desktop を開いて「`test.py` というファイルを作って」と頼んでも、エージェントが「了解しました」と返すだけで、プロジェクトフォルダに `test.py` が作られない。

### 原因

**Chat タブで対話している** 状態です。Claude Desktop 左上には Chat / Cowork / Code の 3 つのタブがあり、ログイン直後は Chat タブで開きます。Chat タブは Claude.ai と同じ通常の対話画面で、あなたのパソコン上のファイルには触れません。

### 対処

1. 画面左上の **「Code」タブ** をクリック
2. プロジェクトフォルダを指定する画面が出るので、作業フォルダ（例: `portfolio-ai`）を選ぶ
3. 画面下部の入力欄に同じ指示を入れ直す

Cowork タブはクラウド上の仮想環境で動くモードで、手元のフォルダには書き込みません。このシリーズの手順では使いません。

## この章の使い方

初見では全部のエラーに遭遇する必要はありません。`python main.py` を実行したときに出た最初のエラーだけ対処して再実行すれば、次のエラーが出るので順に潰していく流れになります。

ここに無いエラーが出たときは、エラー文の冒頭 1 行をそのままエージェントに貼って「これが出た」と伝えるのが最短です。この章で扱ったパターンは初心者が高確率で踏むものに絞っていて、エージェントが対処を出せる範囲のものがほとんどです。

次の章（第 4 章）は、インストールが終わってスクリプトが起動した後、**実行時** に出るエラー（API rate limit、タイムアウト、データ不整合など）を扱います。
