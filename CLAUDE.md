# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

ClingCling は、コピーした内容を理解して次の操作を提案する macOS のメニューバー常駐クリップボードアプリ。Privacy First / Local First で、判定はすべてローカルで行う。Swift / SwiftUI + AppKit 製で、ビルドは SwiftPM のみ。Xcode プロジェクトは存在しない。機能と Privacy の振る舞いは `README.md`、画面の決まりごとは `DESIGN.md` を参照。

## コマンド

```sh
scripts/test.sh                          # 全テスト (Swift Testing)。swift test を直接使わない
scripts/test.sh --filter SearchTests     # 1 スイートのみ
swift build                              # debug ビルド
./scripts/bundle.sh                      # build/ClingCling.app を作って署名 (release)
./scripts/bundle.sh debug                # 同じものを debug で
scripts/create-signing-cert.sh           # 自己署名の証明書を作る（Developer ID がない環境向け）
NOTARIZE=0 scripts/package.sh            # ローカルで試す dmg を作る
scripts/release.sh prepare <version>     # リリースの準備。その後 publish で下書きを作る
swift scripts/check-localization.swift . # 英訳の抜けと、使われていない英訳を検出
open build/ClingCling.app                # 起動
swift scripts/make-icons.swift Resources/Branding/ClingCling-logo.png Resources/Generated  # アイコンとロゴを再生成
scripts/subset-site-font.sh              # LP の見出しフォントを、ページで使う文字に絞って作り直す
```

`bundle.sh` は `build/ClingCling.app` を消してから作り直す。起動中のアプリはいったん終了させ、ビルド後に起動し直す。

## この環境特有の注意点

- **`@State` を使わない。** Command Line Tools の既定の SDK では `@State` がマクロになっていて、そのプラグインが含まれないためビルドできない（`self is immutable`）。ローカルの状態は `ObservableObject` + `@StateObject` で持つ（`SettingsFormState`、`HoverState`）。
- **テストの不安定な失敗。** テストファイルを変更した後の最初のコンパイルが "plugin for module 'TestingMacros' not found" で失敗することがある。`swift test` の末尾には `error: fatalError` とだけ出る。ビルドし直せば通るので、`scripts/test.sh` が再試行する。
- **署名。** `bundle.sh` は `CODESIGN_IDENTITY`、Developer ID（Hardened Runtime 付き）、`ClingCling Self-Signed`、ad-hoc の順に使う。ad-hoc 署名だとビルドのたびにアクセシビリティ権限が外れる。バンドル ID は `io.github.mori-ri.clingcling`。バージョンと `Info.plist` は `Resources/Info.plist`。
- **配布。** `scripts/package.sh` が Developer ID の署名と公証を確かめて dmg を作る（アプリと dmg をそれぞれ公証する）。公証には notarytool のプロファイル `clingcling-notary` が要る。Hardened Runtime の下で Run の Apple Event を送るため、`Resources/ClingCling.entitlements` の entitlement を外さない。
- **リリースノート。** 公開したリリースの本文は、アプリの「お知らせ」のページにそのまま出る。ユーザー向けの日本語で書き、インストールの手順は「インストール」の見出しの節に入れる（アプリでは省く）。
- **リソースは SwiftPM のリソースではない。** `bundle.sh` が `Contents/Resources` にコピーし、コードは `NSImage(named:)` で読む。`swift run` では無いので、コードは SF Symbols にフォールバックする。

## 画面の確認

- DEBUG ビルドには開発用の環境変数がある（`main.swift`）: `CLINGCLING_SNAPSHOT`、`CLINGCLING_APPEARANCE`（`dark` / `light`）、`CLINGCLING_SETTINGS_PAGE`（`general` / `ai` / `privacy` / `applications`）、`CLINGCLING_SETTINGS_SNAPSHOT`。
- 書き出しの `cacheDisplay` は SwiftUI の blur、Liquid Glass、material、behind-window ブラーを描かない。色と配置は確かめられるが、質感と、ガラスの上の文字の色は確かめられない。
- 実データに触れずに動かすときは、`CFFIXED_USER_HOME` で履歴の保存先を分ける。ただし `UserDefaults` は分かれないので、`io.github.mori-ri.clingcling.preview` などの別のバンドル ID を付けた `.app` に入れて動かし、終わったら `defaults delete` する。
- シェルから直接起動すると親のプロセスの権限を引き継ぐ。権限がない状態を見るときは `open -n --env …` で起動する。

## アーキテクチャ

- `ClingClingCore`: UI に依存しない判定ロジック（Privacy Gate、分類、Action の順位、SQLite 保存）。テストはこのターゲットだけを対象にする。
- `ClingCling`: メニューバーアプリ本体。ロジックを足すときは、テストできるよう可能な限り Core に置く。

**取り込みの流れ**: `ClipboardMonitor` が 0.4 秒ごとに `changeCount` を見る（画像は裏で PNG への変換と `TextRecognizer` の OCR を済ませてから渡す）→ `AppModel.capture` → `PrivacyGate.evaluate`（marker → コピー元アプリ → Secret 検出 → 分類 → 外部送信可否 → Retention）→ `ClipStore.save`。一時 Item はディスクに書かず `ClipStore` のメモリ上で保持する（画像も同じ。読み取った文字に Secret があれば一時 Item になる）。

**貼り付け**: `PopupPanel` はフォーカスを奪わないので、直前のアプリが前面のまま残り、`ActionExecutor.pasteIntoFrontmostApp` の ⌘V がそのアプリに届く。貼り付けは必ず `PopupViewModel.pasteWrittenContent` を通す。権限がないときや Secure Input の間は、ポップアップを閉じずに `notice` で理由を出す。

**ポップアップの位置**: `CaretLocator` が AX でキャレットを取る。取れないときはマウスの位置に開き、`AXManualAccessibility` が通るアプリ（Electron など）では 300 ms 後に 1 度だけ取り直して移動する。

**ショートカット**: 値は `ClingClingCore/Shortcut`（検証と表示もここ）。登録は `HotKey`（Carbon）で、切り替えは `AppModel.applyShortcut` を通す。登録できなければ元のショートカットに戻る。記録中は `ShortcutRecorder` が今のショートカットを外し、終わったら戻す。

**更新の確認とお知らせ**（`ClingClingCore/UpdateChecker`、`ClingClingCore/ReleaseNotes`、`NewsPage`）: ClingCling が自分から通信するのはここだけ。許可なく通信しないよう既定はオフで、2 回目の起動時に一度だけ聞く（`ClingClingCore/UpdateCheckPrompt`、`AppDelegate.askAboutUpdateChecksIfNeeded`）。オンなら起動時と 1 日 1 回、GitHub のリリース一覧（`ProjectLinks.releasesAPI`）を問い合わせ、新しい版があればメニューと設定のサイドバーに出す（失敗したら 1 時間後に再試行）。オンにしたら `UpdateChecker.restart` で周期を始め直す。下書き、プレリリース、タグがバージョンの形でないものは除く。ダウンロードはブラウザで最新リリースのページを開くだけで、インストールはしない。設定の「お知らせ」のページ（`SettingsPageID.news`）に最新 5 件のリリースノートを出す。本文は `ReleaseNotes` が見出し・段落・箇条書きに分け、インストールの節、コードブロック、Full Changelog の行は捨てる。押せるリンクは https だけ。最後に見た版（`AppSettings.lastSeenReleaseNotes`）より新しいノートがあれば、サイドバーに印を出す。設定 › 一般 で切り替える（`checksForUpdates`）。オフの間は、お知らせのページでボタンを押したときだけ問い合わせる。問い合わせに履歴や設定を含めない。

**AI への受け渡し**: API は呼ばない。`AIHandoff` がアプリへの貼り付けか URL で渡す。プロンプトは transient marker 付きで一時的にクリップボードへ載せ、`changeCount` が変わっていなければ元の内容へ戻す。

## LP

- `docs/` が LP（GitHub Pages、日本語 `index.html`、英語 `en/index.html`）。ビルドはなく、`docs/assets` の CSS と JS を両方のページが読む。
- 外部のサービスを読み込まない。フッターにそう書いているので、解析ツールや Web フォントの CDN を足さない。
- `docs/assets/site.js` のデモは `ContentClassifier`・`SecretDetector`・`ActionRanker` の規則を移したもの。規則や Action 名を変えたら、こちらとページの一覧も直す。
- 見出しに新しい漢字を使ったら `scripts/subset-site-font.sh` を実行する。

## 規約

- ユーザー向けの文字とコードコメントは日本語。
- UI は日本語と英語に対応する。コードの日本語がそのままキーになり、英訳は `Resources/en.lproj/Localizable.strings` に書く（`bundle.sh` がバンドルにコピーする）。`CFBundleDevelopmentRegion` は `en` で、日本語と英語のどちらでもない Mac では英語を出す。空の `ja.lproj/Localizable.strings` は消さない（日本語でも英訳にフォールバックしてしまう）。
  - `Text("…")` などのリテラルと、`LocalizedStringKey` を受け取る部品は自動で翻訳される。`String` で持つ文言は `String(localized:)` を使う。`Text(String 型の変数)` は翻訳されない。
  - 補間はキーでは `%@`（String）、`%lld`（Int）になり、語順が変わるときは `%1$@` のように番号を付ける。`swift scripts/check-localization.swift .` は補間の個数しか比べないので、型の違いは英語の画面で確かめる。
  - 表示言語は `AppSettings.appLanguage` がアプリのドメインの `AppleLanguages` に書く。再起動で反映される。
  - 検出から外す行には行末に `// no-l10n` を付ける。
- 色は `Theme` のトークンを使い、値を直接書かない。画面の決まりは `DESIGN.md` に従う。
- クリップボードに書いたら `monitor.ignoreCurrentChange()` を呼ぶ（`AppModel` の書き込みメソッドを経由すれば呼ばれる）。
- 保存しないと判断した内容は、理由も含めてログに残さない。
- 履歴のデータ（`~/Library/Application Support/ClingCling`）は Time Machine から除外している（`ClipStore.excludeFromBackup`）。保存先を増やすときは同じ扱いにする。
- GitHub のリンクは `ProjectLinks` に集める。
- ソースコードは MIT License。アイコンとロゴは対象外（README を参照）。
- 出力されたアイコンを直接編集せず、`make-icons.swift` で再生成する。
