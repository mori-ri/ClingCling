#!/bin/zsh
# SwiftPM の実行ファイルを ClingCling.app にまとめる（Xcode 不要）
#   ./scripts/bundle.sh          → build/ClingCling.app（release）
#   ./scripts/bundle.sh debug    → debug ビルド
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/ClingCling.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/ClingCling"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClingCling"

# アイコン（Resources/Generated は scripts/make-icons.swift で生成）
GEN="$ROOT/Resources/Generated"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$GEN/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$GEN/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
# 36px = 18pt@2x。名前の末尾 Template で macOS がテンプレート画像として扱う
cp "$GEN/MenuBarIcon.png" "$APP/Contents/Resources/MenuBarIconTemplate@2x.png"
cp "$GEN/Logo.png" "$APP/Contents/Resources/Logo.png"
# 翻訳。コードの日本語がキーなので、ja.lproj の Localizable.strings は空
cp -R "$ROOT/Resources/ja.lproj" "$ROOT/Resources/en.lproj" "$APP/Contents/Resources/"
# アプリはリポジトリなしで配られるので、ライセンスとアイコン・ロゴの例外も同梱する
{
    cat "$ROOT/LICENSE"
    printf '\nThe app icon and logo are not covered by the MIT License above.\n'
} > "$APP/Contents/Resources/LICENSE.txt"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# 署名。ad-hoc 署名は designated requirement が cdhash になり、リビルドのたびにアクセシビリティ権限が外れる。
# 証明書で署名すれば bundle ID + 証明書で照合されるので権限が残る。
# CODESIGN_IDENTITY → Developer ID → scripts/create-signing-cert.sh の証明書 → ad-hoc の順に使う。
# 証明書が見つからなくてもビルドは失敗させない。
IDENTITIES="$(security find-identity -v -p codesigning || true)"
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    # 名前だと、期限切れと更新後の証明書が同名のときに曖昧になるのでハッシュを使う
    IDENTITY="$(awk '/"Developer ID Application: / { print $2; exit }' <<<"$IDENTITIES")"
fi
if [[ -z "$IDENTITY" ]] && grep -qF '"ClingCling Self-Signed"' <<<"$IDENTITIES"; then
    IDENTITY="ClingCling Self-Signed"
fi
IDENTITY="${IDENTITY:--}"

SIGN_ARGS=(--force --sign "$IDENTITY" --identifier io.github.mori-ri.clingcling)
# ここのパイプラインでは grep -q を使わない。最初の一致で終了すると、pipefail が書き手の SIGPIPE を失敗として返す。
if [[ "$IDENTITY" != - ]] && grep -iF "$IDENTITY" <<<"$IDENTITIES" | grep -F '"Developer ID Application: ' >/dev/null; then
    # 公証には Hardened Runtime が必要。Hardened Runtime では Run アクションの Apple Event に entitlement が要る。
    SIGN_ARGS+=(--options runtime --entitlements "$ROOT/Resources/ClingCling.entitlements")
    # 信頼できるタイムスタンプはネットワークが必要なので、release のときだけ付ける
    if [[ "$CONFIG" == release ]]; then
        SIGN_ARGS+=(--timestamp)
    else
        SIGN_ARGS+=(--timestamp=none)
    fi
else
    if [[ "$IDENTITY" == - ]]; then
        echo "warning: 署名用 ID が無いため ad-hoc 署名します（リビルドごとにアクセシビリティ権限の再付与が必要。scripts/create-signing-cert.sh で解消できます）" >&2
    fi
    SIGN_ARGS+=(--timestamp=none)
fi
codesign "${SIGN_ARGS[@]}" "$APP"
echo "Built $APP (signed with: $IDENTITY)"
