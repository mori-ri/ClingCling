#!/usr/bin/env bash
# release の ClingCling.app を作って zip にする: build/ClingCling-<version>-<arch>.zip
#
# 署名と拡張属性が残るように ditto で zip にする。
#
# 配布する zip は Developer ID で署名し、公証して staple したものだけにする。受け取った人に Gatekeeper の
# 警告が出ないようにするため。コミット済みのソースから作り、条件を満たさなければエラーで止まる。
# 公証には notarytool のキーチェーンプロファイルが要る。最初に一度だけ作る:
#   xcrun notarytool store-credentials clingcling-notary --apple-id <Apple ID> --team-id <team ID>
# 別のプロファイルは CLINGCLING_NOTARY_PROFILE で指定する。
#
# NOTARIZE=0 はローカルで試す用。どの署名でも、未コミットの変更があっても作れる。リリースと取り違えないよう
# ClingCling-<version>-<arch>-local.zip という名前になる。
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
ZIP="build/ClingCling-$VERSION-$ARCH.zip"
[[ "$NOTARIZE" != 0 ]] || ZIP="build/ClingCling-$VERSION-$ARCH-local.zip"

make_zip() {
  rm -f "$1"
  ditto -c -k --keepParent build/ClingCling.app "$1"
}

# 失敗したときにリリースの名前のファイルが残らないよう、先に消す
rm -f "$ZIP"

codesign --verify --strict build/ClingCling.app
# 先に変数に取る。pipefail の下の `codesign | grep -q` は SIGPIPE で失敗し、署名がないように見える。
SIGNATURE="$(codesign -dvv build/ClingCling.app 2>&1)"
# リリースが利用者の検証できない署名に落ちてはいけない
if [[ "$NOTARIZE" != 0 ]] && ! grep -q '^Authority=Developer ID Application: ' <<<"$SIGNATURE"; then
  echo "error: Developer ID で署名されていません。証明書を確認してください (試すだけなら NOTARIZE=0)。" >&2
  exit 1
fi

if [[ "$NOTARIZE" == 0 ]]; then
  make_zip "$ZIP"
  echo "NOTARIZE=0: 公証を省略しました。この zip はローカルで試す専用です。"
else
  SUBMISSION="build/ClingCling-$VERSION-$ARCH-unnotarized.zip"
  make_zip "$SUBMISSION"
  echo "Apple の公証サービスへ送信しています…"
  # 結果の status で判断する。Invalid になった送信は、コマンド自体の失敗ではない。
  RESULT="$(xcrun notarytool submit "$SUBMISSION" --keychain-profile "$PROFILE" --wait --output-format json)" || {
    echo "error: 公証の送信に失敗しました。プロファイル $PROFILE は package.sh の先頭の手順で作成できます。" >&2
    exit 1
  }
  STATUS="$(plutil -extract status raw -o - - <<<"$RESULT")"
  if [[ "$STATUS" != Accepted ]]; then
    echo "error: 公証が通りませんでした (status: $STATUS)。" >&2
    xcrun notarytool log "$(plutil -extract id raw -o - - <<<"$RESULT")" --keychain-profile "$PROFILE" >&2 || true
    exit 1
  fi
  xcrun stapler staple build/ClingCling.app
  spctl --assess --type execute --verbose build/ClingCling.app
  # チケットはバンドルの中に入るので、zip を作り直す
  make_zip "$ZIP"
  rm -f "$SUBMISSION"
fi

echo "Packaged $ZIP"
grep -E "^(Authority|Signature)=" <<<"$SIGNATURE" || true
