# Tidemark for Claude

Claude のプラン使用量（5 時間・7 日間）の残り％を macOS のメニューバーに表示するアプリです。claude.ai の「プラン使用量」と同じ値を、ブラウザを開かずに確認できます。

## 表示内容

メニューバーには 5 時間枠の残り％が `✳ 72%` のように表示されます。クリックすると次のパネルが開きます。

- **5 時間**: 残り％、リセットまでの時間と時刻、ログから集計したトークン数（複数モデルを使っていればモデル別の内訳）
- **7 日間**: 残り％とリセット日時。プランに上限があれば Opus / Sonnet 別の行も表示
- **ログイン時に起動** の切り替え
- 最終更新時刻と終了ボタン

取得に失敗したときはパネルにエラーと「再取得」ボタンが表示され、メニューバーは `✳ —` になります。

## 必要なもの

- macOS 13 以降
- Swift 5.10 以降（Command Line Tools で可、Xcode 不要）
- Claude Code に claude.ai アカウント（Pro / Max）でログイン済みであること

## ビルドと起動

```sh
scripts/build-app.sh
open build/Tidemark.app
```

`scripts/build-app.sh` はリリースビルドして `build/Tidemark.app` を作り、アドホック署名します。Dock には表示されず、メニューバーにだけ常駐します。

### ログイン時に起動

パネルの「ログイン時に起動」をオンにします。登録されるのは起動中のアプリの場所なので、先に `/Applications` へコピーしてから、そちらを起動してオンにしてください。

```sh
cp -R build/Tidemark.app /Applications/
open /Applications/Tidemark.app
```

「システム設定で許可が必要です」と出たら、「開く」から システム設定 > 一般 > ログイン項目 で許可します。

### 動作確認

GUI を起動せずに取得結果だけ確認するには:

```sh
swift run Tidemark --print
```

```
プラン使用量（API）
  5時間: 使用 28.0% / 残り 72%（リセット 2026/10/21 18:00）
  7日間: 使用 41.0% / 残り 59%（リセット 2026/10/24 9:00）
  7日間 Opus: —
  7日間 Sonnet: —
ログ（エントリ 1234 / ブロック 56）
  5時間: 1.2M
```

## 仕組み

### プラン使用量（メイン）

Claude Code が内部で使っている非公式 API `https://api.anthropic.com/api/oauth/usage` から、5 時間と 7 日間（あれば Opus / Sonnet 別）の利用率とリセット時刻を取得します。

- 取得は 2 分ごと。パネルを開いたときも、前回から 30 秒以上たっていれば取り直します。429（回数制限）のときは 10 分待ちます。
- トークンは Claude Code が保存したものを読みます。
  - キーチェーンの `Claude Code-credentials` を `security` コマンドで読みます（Claude Code と同じ方法なので許可ダイアログは出ません）。
  - 見つからなければ `~/.claude/.credentials.json` を読みます。
- トークンが期限切れでも自分では更新しません（更新すると Claude Code 側のログインが切れるため）。Claude Code を使えば更新されます。
- トークンの送り先は `api.anthropic.com` だけです。

### ログのトークン数（参考）

`~/.claude/projects` と `~/.config/claude/projects` 配下の `*.jsonl`（Claude Code のセッションログ）を FSEvents で監視し、追記分だけ読んで今の 5 時間ブロックのトークン使用量を集計します。

- 入力・出力・キャッシュ作成のトークンを合計します。キャッシュ読み込みは桁違いに多く安価なので含めません。
- ブロックは最初のメッセージの時刻（正時に切り捨て）から 5 時間です。
- あくまで参考値です。API が使えないときも、ログから残り％を推定することはしません。

### `CLAUDE_CONFIG_DIR`

Claude Code と同じく `CLAUDE_CONFIG_DIR` を見ます。設定されていると、ログは `$CLAUDE_CONFIG_DIR/projects`（カンマ区切りで複数可）から、トークンはキーチェーンの `Claude Code-credentials-<ハッシュ>` または `$CLAUDE_CONFIG_DIR/.credentials.json` から読みます。

ただし Finder や `open`、ログイン項目から起動したアプリにはシェルの環境変数が渡りません。使う場合は実行ファイルを直接起動してください。

```sh
CLAUDE_CONFIG_DIR=~/.claude-work build/Tidemark.app/Contents/MacOS/Tidemark
```

## トラブルシューティング

| 表示 | 原因と対処 |
| --- | --- |
| Claude Code のログイン情報が見つかりません | Claude Code で `/login` してください。`CLAUDE_CONFIG_DIR` を使っている場合は上記を参照。 |
| トークンの期限切れ。Claude Code を使うと更新されます | Claude Code を一度使うとトークンが更新され、次の取得で直ります。 |
| 取得回数の制限中。しばらく待って再取得します | 10 分後に自動で取り直します。 |
| レスポンスを読めません（API が変わった可能性があります） | 非公式 API の仕様が変わった可能性があります。`Sources/Tidemark/PlanUsageAPI.swift` を直してください。 |

## 注意

- 非公式 API を使っているので、Anthropic 側の変更でいつ動かなくなってもおかしくありません。
- Anthropic とは関係のない個人のツールです。

## ソースの構成

| ファイル | 内容 |
| --- | --- |
| `Sources/Tidemark/TidemarkApp.swift` | エントリポイント（`--print` を含む）とメニューバー・パネルの UI |
| `Sources/Tidemark/UsageModel.swift` | 定期取得、ログ監視、ログイン項目など画面用の状態 |
| `Sources/Tidemark/PlanUsageAPI.swift` | 使用量 API の呼び出しとトークンの読み込み |
| `Sources/Tidemark/LogReader.swift` | セッションログ（JSONL）の差分読み込み |
| `Sources/Tidemark/Usage.swift` | 5 時間ブロックの集計と表示用フォーマット |
| `Sources/Tidemark/DirectoryWatcher.swift` | FSEvents によるディレクトリ監視 |
| `Resources/Info.plist` | アプリの Info.plist（`LSUIElement` でメニューバー常駐） |
| `scripts/build-app.sh` | `.app` のビルドと署名 |

## アンインストール

パネルで「ログイン時に起動」をオフにしてから終了し、`Tidemark.app` を削除します。設定ファイルやキャッシュは作りません。
