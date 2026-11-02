---
name: create-pr
description: ClingCling の変更から GitHub の Pull Request を作る手順。main にいれば新しいブランチを切ってコミットし、main に追従し、公開してはいけないファイルや秘密情報がないか確かめ、/code-review と /security-review で見つかった問題を直し、テストとビルドを通してから PR を作る。「PR を作って」「プルリク出して」「この変更を PR にして」「レビューに出したい」「push して PR」など、変更を PR として出したいときは必ずこのスキルを使うこと。git commit だけ、push だけを頼まれた場合は対象外。
---

# PR 作成

変更を PR として出すまでの手順。PR を作る前にレビュー・テスト・秘密情報のチェックを済ませ、指摘はできる限り直してから出す。ユーザーが後から見て「何を確認済みで、何を直したか」がわかる PR にするのが目的。

各ステップは順番に進める。途中で止まる条件に当たったら、そこで状況を説明してユーザーに判断を仰ぐ。黙って飛ばしたり、失敗を隠して先に進んだりしない。

## 1. 現状の確認

```sh
git status --short
git branch --show-current
git fetch origin
gh pr view --json url,state 2>/dev/null   # このブランチに PR が既にあるか
```

- `gh` が未認証なら、`! gh auth login` を実行してもらうよう案内して止まる。
- このブランチに open な PR が既にあるなら、新しく作らずに「既存の PR に push して更新するか」をユーザーに確認する。
- main との差分もコミットされていない変更もなければ、PR にするものがないと伝えて終わる。

## 2. ブランチとコミット

**main にいる場合**は、変更内容を表すブランチを新しく作ってからコミットする。main に直接コミットや push はしない(main はレビューとテストを通ったものだけが入る場所なので)。

- ブランチ名は英語の kebab-case で、変更内容がわかる 2〜3 語にする(例: `settings-sidebar`、`custom-shortcut`、`english-localization`)。
- `git switch -c <branch>` で作る。コミットされていない変更はそのまま新しいブランチに移る。
- main にだけあってまだ push していないコミット(`git log origin/main..main`)があれば、それも新しいブランチに含まれる。その場合はローカルの main を `git branch -f main origin/main` で戻してよいかユーザーに確認する。

**コミットされていない変更がある場合**(どのブランチでも):

- `git diff` で中身を確認する。PR の目的と関係なさそうな変更が混ざっていれば、含めるかどうかユーザーに聞く。
- `git add -A` はしない。ファイルを明示して add する(公開してはいけないファイルが紛れ込むのを防ぐため)。
- コミットメッセージは既存の履歴に合わせて英語の命令形 1 行(例: `Fix popup sometimes opening away from the text cursor`)。必要なら空行の後に本文を書く。
- ハーネスがコミットの attribution 行を指示している場合は、その行を末尾に付ける。

## 3. main の最新に追従

```sh
git rev-list --count HEAD..origin/main
```

0 でなければ `git rebase origin/main` する。先に追従しておくのは、レビューとテストを最終的な差分に対して行うため。

- コンフリクトしたら、自明な場合(import の並び、片方にしかない追加など)だけ解消して続ける。意図の判断が必要なら `git rebase --abort` して、衝突しているファイルと内容をユーザーに見せて止まる。
- このブランチが既に push 済みなら、後の push は `--force-with-lease` が必要になる。そのことを最後の報告に含める。

## 4. 公開してはいけないファイル・秘密情報のチェック

```sh
.claude/skills/create-pr/scripts/check_diff.sh origin/main
```

origin/main からの全コミットと、作業ツリーの変更を調べる。対象は次のとおり。

- **ファイル**: `build/`、`.build/`、`.env`、`*.secret`、証明書・鍵、履歴の DB(`*.sqlite`)、`.DS_Store`、`xcuserdata/`
- **追加した行**: Anthropic / OpenAI / AWS / Bedrock のキー、秘密鍵、`apiKey = "..."` のような代入

終了コードが 2 のときは基準のブランチが見つかっていないので、`git fetch origin` してからやり直す。

終了コードが 1 のときは、出力の 1 件ずつを判断する。

- **テスト用のダミー値は問題ない。** `Tests/ClingClingCoreTests/` の `SecretDetector` や `PrivacyGate` のテストは、検出を確かめるために秘密情報に似た文字列を使う。本物のキーでないことだけ確かめる。
- **本物に見える秘密情報や、含めてはいけないファイルがあれば止まる。** 自動では直さない。まだコミットしていなければ unstage で済むが、コミット済みなら履歴の書き換えが必要で、push 済みならキーの無効化も必要になる。どれに当たるかを説明して、ユーザーに判断してもらう。
- 実際にコピーした内容(履歴の本文やスクリーンショット)を、テスト、ドキュメント、コミットメッセージに書き写していないかも差分を見て確認する。スクリプトでは検出できない。

## 5. コードレビュー: /code-review --fix

Skill ツールで `code-review` を `--fix` 付きで呼ぶ。レビューが終わると、指摘の修正が作業ツリーに適用される。

- 修正を適用したら `git diff` で中身を確認する。PR の目的から外れる変更や、設計の判断が必要な変更(API の変更、ユーザーに見える挙動の変更など)が入っていたら、その部分は戻してユーザーに相談する。
- 指摘の件数、直した内容、直さなかった指摘とその理由をメモしておく。PR 本文と最後の報告に使う。

## 6. セキュリティレビュー: /security-review

Skill ツールで `security-review` を呼ぶ。このスキルには自動修正がないので、見つかった問題は自分で直す。

`security-review` は「最後の返答はレポートだけにする」と指示するが、ここではレポートを結果のメモとして受け取るだけにする。返答を終えずに、このまま指摘の対応と次の手順に進む。

- 確度の高い指摘は直す。直し方が複数あって仕様の判断が要る場合(認証情報の保存先を変える、など)は、案を示してユーザーに確認する。
- 誤検知と判断した指摘は、理由をメモしておく。
- ClingCling で特に見るべき点: `PrivacyGate` を通さずに保存や外部送信をする経路ができていないか(判定できないものは Fail Closed)。Secret や認証コードがディスクに書かれないか。ログ(`NSLog`)にクリップボードの内容や保存しなかった理由を出していないか。本文が Mac の外に出るのはユーザーの明示操作のときだけか。履歴ファイルの権限(0600)と Time Machine の除外が保たれているか。`runInTerminal` の AppleScript や AI の URL テンプレートへの埋め込みでエスケープが漏れていないか。クリップボードの復元が他アプリのデータを壊さないか。開発用の環境変数が `#if DEBUG` の中にあるか。

5 と 6 で直した内容はまとめて 1 つのコミットにする(例: `Address review findings`)。何も直さなかったならコミットは不要。

## 7. テストとビルド

レビューの修正を含めた最終的な状態を確かめたいので、このステップはレビューの後に行う。CI は同じ確認をするが、失敗に早く気付けるよう手元でも通す。

```sh
scripts/test.sh
swift scripts/check-localization.swift .
./scripts/bundle.sh
```

- テストは `swift test` を直接使わず `scripts/test.sh` を使う。`TestingMacros` の plugin not found は、この環境ではよくある不安定な失敗(`swift test` の末尾には `error: fatalError` とだけ出る)。`scripts/test.sh` がリトライするので、それでも失敗したときだけ問題として扱う。
- `bundle.sh` は `build/ClingCling.app` を消して作り直す。そこから起動中のアプリがあれば、ビルドの前に終了させ、ビルド後に `open build/ClingCling.app` で起動し直す。止めている間のコピーは履歴に入らないので、そのことを報告に含める。
- 失敗したら原因を調べる。この PR の変更が原因なら直してコミットし、テストを通し直す。変更と関係のない失敗(既存の不安定なテスト、環境の問題)なら、その内容をユーザーに伝えて、PR を作るか判断してもらう。
- 通ったテストの件数を控えておく(PR 本文に書く)。

## 8. push と PR 作成

```sh
git push -u origin <branch>             # rebase した push 済みブランチなら --force-with-lease
```

PR 本文は既存の PR(`gh pr list --state merged --limit 3 --json title,body` で確認できる)に合わせて日本語で書く。タイトルも日本語で、変更内容がひと目でわかるようにする。

```markdown
## 概要
<何を、なぜ変えたかを 2〜3 行で>

## 変更内容
- <ユーザーから見た変化を先に、実装の変更を後に>

## レビュー
- /code-review: <指摘 N 件。直したもの / 直さなかったもの(理由)>
- /security-review: <指摘 N 件、または「指摘なし」>

## テスト
- `scripts/test.sh`: N 件すべて成功
- `swift scripts/check-localization.swift .`: 問題なし
- `./scripts/bundle.sh` でビルド成功
- <実際の画面で確認したか。していなければ「画面の見た目は未確認」と書く>
```

本文に書くのは、実際に確認したことだけにする。見た目を確かめていないなら、確かめていないと書く。ハーネスが PR 本文の attribution 行を指示している場合は、その行を末尾に付ける。

```sh
gh pr create --base main --title "<タイトル>" --body "$(cat <<'EOF'
<本文>
EOF
)"
```

## 9. CI の確認

push すると `.github/workflows/ci.yml` が動く。次のように確認する。

```sh
gh pr checks <PR番号> --watch --fail-fast
```

CI は時間がかかることがあるので、Bash の `run_in_background` で実行し、完了を待つ。

- 成功したら報告に含める。
- 失敗したら `gh run view <run-id> --log-failed` でログを確認する。修正して push するかはユーザーに確認する。

## 最後の報告

ユーザーには短くまとめて伝える。

- PR の URL
- ブランチ(新しく作ったなら、その名前)
- レビューで直したこと、直さなかったこと
- テストとビルドの結果(CI があればその結果も)
- 途中でユーザーの判断に任せたこと(force push をした、無関係な変更を除いた、など)
