#!/bin/zsh
# SwiftPM の実行ファイルを ClingCling.app にまとめる（Xcode 不要）
#   ./scripts/bundle.sh          → build/ClingCling.app（release）
#   ./scripts/bundle.sh debug    → debug ビルド
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/ClingCling.app"
VERSION="0.1.0"

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

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ClingCling</string>
    <key>CFBundleDisplayName</key><string>ClingCling</string>
    <key>CFBundleIdentifier</key><string>com.clingcling.app</string>
    <key>CFBundleExecutable</key><string>ClingCling</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Run アクションでコマンドを Terminal に渡すために使用します。</string>
</dict>
</plist>
PLIST

# 署名（Keychain・アクセシビリティ権限の紐付けに必要）
# ad-hoc 署名だと designated requirement が cdhash になり、リビルドのたびに
# アクセシビリティ権限が無効化される。証明書で署名すれば bundle ID + 証明書で照合されるので持続する。
#   CODESIGN_IDENTITY="名前" で指定。未指定ならキーチェーンの最初の署名用 ID を使う
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' 'NR==1 && /"/ {print $2}')}"
if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
    echo "warning: 署名用 ID が無いため ad-hoc 署名します（リビルドごとにアクセシビリティ権限の再付与が必要）" >&2
    codesign --force --sign - --timestamp=none "$APP"
fi
echo "Built $APP"
