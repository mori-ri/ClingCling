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
open build/ClingCling.app                # 起動
swift scripts/make-icons.swift Resources/Branding/ClingCling-logo.png Resources/Generated  # アイコンとロゴを再生成
```

`bundle.sh` は `build/ClingCling.app` を消してから作り直す。起動中のアプリはいったん終了させ、ビルド後に起動し直す。

## この環境特有の注意点

- **`@State` を使わない。** Command Line Tools の既定の SDK では `@State` がマクロになっていて、そのプラグインが含まれないためビルドできない（`self is immutable`）。ローカルの状態は `ObservableObject` + `@StateObject` で持つ（`SettingsFormState`、`HoverState`）。
- **テストの不安定な失敗。** テストファイルを変更した後の最初のコンパイルが "plugin for module 'TestingMacros' not found" で失敗することがある。`swift test` の末尾には `error: fatalError` とだけ出る。ビルドし直せば通るので、`scripts/test.sh` が再試行する。
- **署名。** `bundle.sh` はキーチェーンの最初の署名用 ID を使う。ad-hoc 署名だとビルドのたびにアクセシビリティ権限が外れる。バンドル ID は `com.clingcling.app`。
- **リソースは SwiftPM のリソースではない。** `bundle.sh` が `Contents/Resources` にコピーし、コードは `NSImage(named:)` で読む。`swift run` では無いので、コードは SF Symbols にフォールバックする。

## 画面の確認

- DEBUG ビルドには開発用の環境変数がある（`main.swift`）: `CLINGCLING_SNAPSHOT`、`CLINGCLING_APPEARANCE`（`dark` / `light`）、`CLINGCLING_SETTINGS_PAGE`（`general` / `ai` / `privacy` / `applications`）、`CLINGCLING_SETTINGS_SNAPSHOT`。
- 書き出しの `cacheDisplay` は SwiftUI の blur、Liquid Glass、material、behind-window ブラーを描かない。色と配置は確かめられるが、質感と、ガラスの上の文字の色は確かめられない。
- 実データに触れずに動かすときは、`CFFIXED_USER_HOME` で履歴の保存先を分ける。ただし `UserDefaults` は分かれないので、`com.clingcling.preview` などの別のバンドル ID を付けた `.app` に入れて動かし、終わったら `defaults delete` する。
- シェルから直接起動すると親のプロセスの権限を引き継ぐ。権限がない状態を見るときは `open -n --env …` で起動する。

## アーキテクチャ

- `ClingClingCore`: UI に依存しない判定ロジック（Privacy Gate、分類、Action の順位、SQLite 保存）。テストはこのターゲットだけを対象にする。
- `ClingCling`: メニューバーアプリ本体。ロジックを足すときは、テストできるよう可能な限り Core に置く。

**取り込みの流れ**: `ClipboardMonitor` が 0.4 秒ごとに `changeCount` を見る → `AppModel.capture` → `PrivacyGate.evaluate`（marker → コピー元アプリ → Secret 検出 → 分類 → 外部送信可否 → Retention）→ `ClipStore.save`。一時 Item はディスクに書かず `ClipStore` のメモリ上で保持する。

**貼り付け**: `PopupPanel` はフォーカスを奪わないので、直前のアプリが前面のまま残り、`ActionExecutor.pasteIntoFrontmostApp` の ⌘V がそのアプリに届く。貼り付けは必ず `PopupViewModel.pasteWrittenContent` を通す。権限がないときや Secure Input の間は、ポップアップを閉じずに `notice` で理由を出す。

**ポップアップの位置**: `CaretLocator` が AX でキャレットを取る。取れないときはマウスの位置に開き、`AXManualAccessibility` が通るアプリ（Electron など）では 300 ms 後に 1 度だけ取り直して移動する。

**AI への受け渡し**: API は呼ばない。`AIHandoff` がアプリへの貼り付けか URL で渡す。プロンプトは transient marker 付きで一時的にクリップボードへ載せ、`changeCount` が変わっていなければ元の内容へ戻す。

## 規約

- ユーザー向けの文字とコードコメントは日本語。
- 色は `Theme` のトークンを使い、値を直接書かない。画面の決まりは `DESIGN.md` に従う。
- クリップボードに書いたら `monitor.ignoreCurrentChange()` を呼ぶ（`AppModel` の書き込みメソッドを経由すれば呼ばれる）。
- 保存しないと判断した内容は、理由も含めてログに残さない。
- 履歴のデータ（`~/Library/Application Support/ClingCling`）は Time Machine から除外している（`ClipStore.excludeFromBackup`）。保存先を増やすときは同じ扱いにする。
- 出力されたアイコンを直接編集せず、`make-icons.swift` で再生成する。
