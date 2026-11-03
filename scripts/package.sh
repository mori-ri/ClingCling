#!/usr/bin/env bash
# release の ClingCling.app を作って dmg にする: build/ClingCling-<version>-<arch>.dmg
#
# dmg には ClingCling.app と /Applications へのリンクを入れ、開いたらドラッグでインストールできるようにする。
#
# 配布する dmg は Developer ID で署名し、公証して staple したものだけにする。受け取った人に Gatekeeper の
# 警告が出ないようにするため。コミット済みのソースから作り、条件を満たさなければエラーで止まる。
# 公証は 2 回行う。先にアプリを公証して staple し（/Applications にコピーした後もオフラインで検証できるように）、
# それを入れた dmg を署名して公証する。
# 公証には notarytool のキーチェーンプロファイルが要る。最初に一度だけ作る:
#   xcrun notarytool store-credentials clingcling-notary --apple-id <Apple ID> --team-id <team ID>
# 別のプロファイルは CLINGCLING_NOTARY_PROFILE で指定する。
#
# NOTARIZE=0 はローカルで試す用。どの署名でも、未コミットの変更があっても作れる。dmg は署名しない。
# リリースと取り違えないよう ClingCling-<version>-<arch>-local.dmg という名前になる。
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${CLINGCLING_NOTARY_PROFILE:-clingcling-notary}"
NOTARIZE="${NOTARIZE:-1}"

if [[ "$NOTARIZE" != 0 && -n "$(git status --porcelain)" ]]; then
  echo "error: 作業ツリーに未コミットの変更があります。配布物はコミット済みのソースから作ってください (試すだけなら NOTARIZE=0)。" >&2
  exit 1
fi

./scripts/bundle.sh release

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ARCH="$(uname -m)"
DMG="build/ClingCling-$VERSION-$ARCH.dmg"
[[ "$NOTARIZE" != 0 ]] || DMG="build/ClingCling-$VERSION-$ARCH-local.dmg"

# 一時ファイルはここにまとめ、途中で失敗しても終了時に消す
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

make_dmg() {
  local staging="$WORK/dmg"
  rm -rf "$staging"
  mkdir "$staging"
  ditto build/ClingCling.app "$staging/ClingCling.app"
  ln -s /Applications "$staging/Applications"
  rm -f "$1"
  hdiutil create -quiet -volname ClingCling -srcfolder "$staging" -format UDZO "$1"
  rm -rf "$staging"
}

# 公証に送り、通らなければログを出して止まる
notarize() {
  echo "Apple の公証サービスへ $(basename "$1") を送信しています…"
  # 結果の status で判断する。Invalid になった送信は、コマンド自体の失敗ではない。
  local result status
  result="$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json)" || {
    echo "error: 公証の送信に失敗しました。プロファイル $PROFILE は package.sh の先頭の手順で作成できます。" >&2
    exit 1
  }
  status="$(plutil -extract status raw -o - - <<<"$result")"
  if [[ "$status" != Accepted ]]; then
    echo "error: 公証が通りませんでした (status: $status)。" >&2
    xcrun notarytool log "$(plutil -extract id raw -o - - <<<"$result")" --keychain-profile "$PROFILE" >&2 || true
    exit 1
  fi
}

# 失敗したときにリリースの名前のファイルが残らないよう、先に消す
rm -f "$DMG"

codesign --verify --strict build/ClingCling.app
# 先に変数に取る。pipefail の下の `codesign | grep -q` は SIGPIPE で失敗し、署名がないように見える。
SIGNATURE="$(codesign -dvv build/ClingCling.app 2>&1)"
# リリースが利用者の検証できない署名に落ちてはいけない
if [[ "$NOTARIZE" != 0 ]] && ! grep -q '^Authority=Developer ID Application: ' <<<"$SIGNATURE"; then
  echo "error: Developer ID で署名されていません。証明書を確認してください (試すだけなら NOTARIZE=0)。" >&2
  exit 1
fi

if [[ "$NOTARIZE" == 0 ]]; then
  make_dmg "$DMG"
  echo "NOTARIZE=0: 署名と公証を省略しました。この dmg はローカルで試す専用です。"
else
  # アプリの公証は zip で送る（notarytool はバンドルをそのまま受け取らない）。署名と拡張属性が残るよう ditto を使う。
  SUBMISSION="build/ClingCling-$VERSION-$ARCH-unnotarized.zip"
  rm -f "$SUBMISSION"
  ditto -c -k --keepParent build/ClingCling.app "$SUBMISSION"
  notarize "$SUBMISSION"
  rm -f "$SUBMISSION"
  xcrun stapler staple build/ClingCling.app
  spctl --assess --type execute --verbose build/ClingCling.app

  # dmg はアプリと同じ証明書で署名する。名前だと期限切れと更新後の証明書が同名のときに曖昧になるので、
  # アプリの署名から証明書を取り出し、そのハッシュで指定する。
  # codesign -d は Executable= の行を stderr に出すので捨てる。失敗したときは理由を出して止まる。
  codesign -d --extract-certificates="$WORK/cert" build/ClingCling.app 2>/dev/null || {
    echo "error: アプリの署名から証明書を取り出せませんでした。" >&2
    exit 1
  }
  IDENTITY="$(shasum -a 1 "$WORK/cert0" | awk '{ print toupper($1) }')"

  # 失敗しても、署名や公証を終えていない dmg がリリースの名前で残らないよう、別名で作ってから移す
  UNSIGNED="build/ClingCling-$VERSION-$ARCH-unnotarized.dmg"
  make_dmg "$UNSIGNED"
  codesign --sign "$IDENTITY" --timestamp "$UNSIGNED"
  notarize "$UNSIGNED"
  xcrun stapler staple "$UNSIGNED"
  spctl --assess --type open --context context:primary-signature --verbose "$UNSIGNED"
  mv "$UNSIGNED" "$DMG"
fi

echo "Packaged $DMG"
grep -E "^(Authority|Signature)=" <<<"$SIGNATURE" || true
