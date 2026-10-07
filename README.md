<p align="center"><img src="Resources/Branding/ClingCling-logo.png" alt="ClingCling" width="240"></p>

# ClingCling

コピーした内容を理解して、次の操作を提案する macOS 用クリップボード（Intent-Aware Clipboard）。
**Privacy First / Local First** — 安全だと判断できたものだけが、ユーザーの明示操作時に限って AI（Claude / ChatGPT のアプリや Web）に渡されます。API キーは不要です。

## 使い方

```sh
./scripts/bundle.sh          # build/ClingCling.app を作成（Xcode 不要、CLT のみで可）
open build/ClingCling.app
```

- メニューバーに常駐。コピーしても通知は出ません。
- **⌘⇧V** でテキストカーソルの横にポップアップを開く（カーソル位置が取れないアプリではマウスの位置。位置の取得にはアクセシビリティ権限が必要）
  - 入力するとそのまま絞り込み / `↑↓` 選択 / `↩`・クリックで貼り付け / `1–9` 履歴の n 番を貼り付け（検索語が空のとき）
  - `→` アクションメニュー / `⌘1–3` 各 Smart Action / `⌘4–9` 自作の AI Action / `⌘P` Pin / `⌘⌫` 削除 / `esc` 閉じる
- **画像**（スクリーンショット、プレビューや Web からの画像コピー）も履歴に残る。行にサムネイル、`→` のアクションメニューに大きめのプレビュー。`↩` で画像として貼り付け、「ダウンロードに保存」で PNG を書き出し
  - テキストも一緒に載っているコピー（表計算のセルなど）はテキストとして扱う。Finder でのファイルコピーは対象外
- AI Action（説明する / 文章を整える / 短くする / 翻訳する）は Settings → AI で有効化。API は直接呼ばず、指示文を付けた本文を AI に渡します。
  - **アプリ**（既定: Claude アプリ / ChatGPT アプリ）: アプリを前面に出し、⌘N で新しいチャットを開いて貼り付け（任意で ↩ 送信）。終わったらクリップボードを元に戻す。アクセシビリティ権限が必要
  - **URL**（既定: `https://claude.ai/new?q={prompt}` / `https://chatgpt.com/?q={prompt}`）: `{prompt}`（指示 + 本文）/ `{instruction}` / `{text}` を埋め込んで開く。8,000 文字を超える URL は送らない
  - 送り先の追加・編集、指示文の編集は Settings → AI。確認画面では `⇥` で送り先を切り替え
  - **自作の Action**: Settings → AI で「名前 + 指示文（+ 送り先）」を登録すると、アクションメニューの末尾に並ぶ（例: 「3 行で要約」「敬語に直す」）

アイコンはロゴから生成します（ロゴを差し替えたら再実行）:

```sh
swift scripts/make-icons.swift Resources/Branding/ClingCling-logo.png Resources/Generated
```

開発時:

```sh
swift test                   # Core ロジックのテスト
swift build && .build/debug/ClingCling
CLINGCLING_SNAPSHOT=/tmp/p.png .build/debug/ClingCling   # ポップアップを PNG に書き出す（DEBUG のみ）
```

## 構成

| モジュール | 役割 |
|---|---|
| `ClingClingCore/PrivacyGate` | 最前段のローカル判定。Pasteboard marker → コピー元アプリ → Secret 検出 → 分類 → 外部送信可否（許可リスト方式・Fail Closed）→ Retention |
| `ClingClingCore/SecretDetector` | 既知 Secret の正規表現、クレジットカード（Luhn）、高エントロピー文字列、個人情報 |
| `ClingClingCore/ContentClassifier` | ルールベース分類（text / url / code / command / error / email / address / json / credential / verification_code / other） |
| `ClingClingCore/ActionRanker` | 分類＋コピー元アプリで候補を作り、ローカル利用統計で並べ替えて最大 3 つ |
| `ClingClingCore/ClipStore` | SQLite（`~/Library/Application Support/ClingCling`、0600）。画像本体は同じ場所の `images/<hash>.png`（0600、行が消えるとファイルも削除）。重複排除、保存期間、Action 統計、First Action Selection Rate |
| `ClingCling/*` | メニューバー、Clipboard 監視、⌘⇧V（Carbon HotKey）、ポップアップ、Action 実行、AI への受け渡し（`AIHandoff`）、設定 |

## Privacy の振る舞い

| 入力 | 扱い |
|---|---|
| Concealed / Transient marker、Password Manager、Never Capture アプリ | キャプチャしない |
| 既知 Secret（API キー、JWT、秘密鍵、接続文字列、カード番号…）、認証コード | **ディスクに書かず**メモリで 5 分保持、一覧ではマスク、外部送信不可 |
| 高エントロピー文字列（未知 Token・長い Hex） | 保存するが Local only |
| 個人情報（メール・電話番号）、住所、Local Only アプリ、分類不能 | 保存するが Local only |
| 画像 | 中身を検査できないので保存はするが常に Local only（marker・Password Manager・アプリ単位のポリシーはテキストと同じく適用） |
| それ以外の text / url / code / command / error / json | 明示操作時のみ AI / Search を提示（渡す前に確認） |

## MVP v0.1 の範囲外 / 既知の制限

- テキストと画像が対象（ファイルは未対応）。画像は 30 MB まで、件数は履歴の上限・保存期間に含まれる
- ショートカットは ⌘⇧V 固定（多くのアプリの「スタイルを合わせてペースト」を上書きします）
- 履歴 DB は暗号化していない（ファイル権限 0600 のみ）
- Copy Session、Semantic Search、ローカル LLM 分類、Jev 連携は未実装
