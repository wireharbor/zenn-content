---
title: "エラー図鑑（2）実行時編"
free: false
---

この章では、第 3 章のインストール系エラーを越えて `python main.py` が起動するようになった後、スクリプトが実際に動いているときに出るエラーを扱います。

スクリプトが動き始めると次に待っているのは、外部サービス（Google Sheets、OAuth 認証、OS やネットワーク）との境界で出るエラーです。ここに挙げる 5 種は筆者が自作のポートフォリオ API を 3 ヶ月以上動かす中で実際に踏んだものから拾っています。

MCP / OpenAPI 接続段階で出る実行時エラー（ツールが認識されない、レスポンスが切れる等）は、性質が異なるため第 6 章（接続編）で扱います。

## 1. `429 Too Many Requests` / `RESOURCE_EXHAUSTED`（Google Sheets API クォータ超過）

### 症状

```
google.api_core.exceptions.TooManyRequests: 429 rate limit exceeded
```

または

```
gspread.exceptions.APIError: {'code': 429,
  'status': 'RESOURCE_EXHAUSTED',
  'message': 'Quota exceeded for quota metric ...'}
```

### 原因

Google Sheets API の **1 分あたりのリクエスト数上限** を超えました。Google のデフォルト上限はプロジェクト単位で 1 分 300 リクエスト、ユーザー単位で 1 分 60 リクエスト程度です。

よくあるのはループの中で 1 行ずつ `worksheet.cell(r, c)` を呼ぶ実装で、100 行読むだけで 100 リクエストを消費します。並列実行の別プロセスが同じシートを読んでいるケースも踏みます。

### 対処

1. **1 シートをまとめて読む**: `worksheet.get_all_values()` や `worksheet.get("A1:Z1000")` のように、範囲を指定して一度に取得する形に書き換える
2. **ローカルキャッシュ**: シートのスナップショットを JSON で手元に保存しておき、以後の集計はキャッシュから読む。毎日1回だけシートに接続すれば足りる使い方なら、この形で上限に触れません
3. **指数バックオフ**: 429 が出たら数秒待って再試行する。gspread に `with_retry` を噛ませるか、`tenacity` ライブラリで包みます

長期運用では「シートから読むのは1日1回」「以後はキャッシュ参照」の設計にするのが一番安定します。この設計の詳細は第 14 章（データの新鮮さ）で扱います。

## 2. セルの型不整合（`ValueError` / `TypeError`）

### 症状

```
ValueError: could not convert string to float: '¥1,234,567'
```

または計算の途中で突然

```
TypeError: unsupported operand type(s) for +: 'float' and 'str'
```

### 原因

Google Sheets のセルに数値を入れたつもりが、実態は **文字列** だった、というズレです。

よくあるパターン:

- `¥` や `%` などの記号付きで書式設定された数値。見た目は数字だが gspread には文字列で返る
- 他シートから `IMPORTRANGE` で持ち込んだ数値が文字列として届く
- 手入力時に全角数字になっていた
- 数式セルが `#N/A` や `Loading...` を返している（IMPORTRANGE のロード中など）
- 行の途中に空セルがあり、`row[5]` でインデックス外を踏む

### 対処

読み取り側で **型変換と欠損検出** を噛ませます。

```python
def _to_float(v):
    try:
        return float(str(v).replace(",", "").replace("¥", "").replace("%", ""))
    except (TypeError, ValueError):
        return None
```

こういう守りを入れておくと、想定外の文字列が入ってきても `None` として扱われ、プログラム全体が止まらなくなります。None のまま集計に混ざるのは避けたいので、`None` が出た行はログに出して後で手当てする運用にします。

`Loading...` を返すセルは、数秒待てば値が確定することが多いので、読み取り直前に数秒のスリープを挟むか、読んで `Loading...` が混ざっていたらリトライする処理を入れます。

## 3. `Address already in use`（uvicorn ポート衝突）

### 症状

FastAPI 化したスクリプトを `uvicorn main:app --reload` で起動すると:

```
ERROR:    [Errno 48] Address already in use
```

（Windows は `[Errno 10048]`、Linux は `[Errno 98]`）

### 原因

前回起動した uvicorn が終了せずにバックグラウンドに残っているか、別のアプリが同じポート（既定 8000）を使っています。Ctrl+C で止めたつもりでもプロセスが残ることがあります。

### 対処

まずポートを占有しているプロセスを確認します。

Windows:

```
netstat -ano | findstr :8000
taskkill /PID <表示された PID> /F
```

Mac / Linux:

```
lsof -i :8000
kill -9 <表示された PID>
```

再起動で直らない場合は uvicorn の起動オプションで別ポートにします。

```
uvicorn main:app --reload --port 8001
```

Render 等のクラウド側では `$PORT` 環境変数で指定されるので手元とは独立しています（この挙動は第 5 章で扱います）。

## 4. `invalid_grant` / `RefreshError`（OAuth token の期限切れ）

### 症状

半年ぐらい動かしていた後に突然:

```
google.auth.exceptions.RefreshError:
  ('invalid_grant: Token has been expired or revoked.', ...)
```

あるいは

```
HttpError 401: Request had invalid authentication credentials.
```

### 原因

サービスアカウントの鍵そのもの、または古い OAuth の refresh token が Google 側で失効した状態です。原因になるケース:

- Google Cloud Console でサービスアカウントの鍵をローテーション（手動削除 or 期限）
- 組織ポリシーで鍵の有効期間が短く設定されている
- Workspace 管理者がサービスアカウントのアクセスを取り消した
- 長期間使っていないプロジェクトで Google 側が自動無効化

### 対処

1. Google Cloud Console → IAM と管理 → サービスアカウント → 該当アカウントのキータブで新しい鍵を発行
2. ダウンロードされた JSON を `credentials.json` として再配置（古いファイルは削除）
3. サービスアカウントのメールアドレスが、対象スプレッドシートの共有先に今でも入っているかを確認（たまに共有解除されている）
4. スクリプトを再起動

鍵の再発行はアカウント単位なので、同じ鍵を複数サービスで共有している場合、他のスクリプトも同時に更新が必要です。

## 5. `UnicodeEncodeError: 'cp932' codec can't encode character`（Windows の日本語出力）

### 症状

Windows PowerShell やコマンドプロンプトで `print("維持率")` や `print(data)` を実行すると:

```
UnicodeEncodeError: 'cp932' codec can't encode character '\u2014' in position 3:
  illegal multibyte sequence
```

あるいは画面に `???` だけが並ぶ。

### 原因

Windows のコンソールのデフォルト文字コードが **cp932（Shift-JIS）** で、絵文字・中点（·）・ダッシュ（—）・JIS にない漢字などを出力できません。Python 側は UTF-8 で文字列を持っていても、標準出力に書き込むタイミングで cp932 変換が失敗します。

### 対処

### 暫定: ターミナル側を UTF-8 に切り替える

PowerShell で:

```
chcp 65001
```

これでそのターミナルでは UTF-8 出力が通ります。ターミナルを閉じると戻るので、運用にするなら PowerShell プロファイルに書いておくか、バッチファイルの先頭に仕込みます。

### 恒久: スクリプト側で強制 UTF-8

main.py の先頭で:

```python
import sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
```

これでスクリプト内の全 print がどの端末でも UTF-8 で出ます。スクリプトを配布する場合はこちらのほうが確実です。

JSON として出す場合は `json.dumps(data, ensure_ascii=False)` を併用すると、日本語がエスケープされずにそのまま出ます。

## この章の使い方

ここまでの 5 種は、ローカル（自分のパソコン）でスクリプトを動かしている段階で出るものです。次の章（第 5 章）は、このスクリプトをクラウド（Render 等）にデプロイしたときに出る **デプロイ編** のエラーを扱います。

クラウドの環境変数が渡らない、Render がスリープして最初の1回が遅い、ビルドは通るが起動直後にクラッシュする、といったパターンが中心になります。
