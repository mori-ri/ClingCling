#!/usr/bin/env bash
# LP（docs/）の見出しのフォントを、ページで使う文字だけに絞って書き出す。
# 新しい漢字を見出しに使ったら実行する。足りない文字はシステムのフォントで表示される。
#
# 使い方: scripts/subset-site-font.sh
# 必要なもの: python3（fonttools と brotli は一時的な環境に入れる）
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" -q install fonttools brotli
curl -fsSL -o "$WORK/font.ttf" \
  "https://github.com/google/fonts/raw/main/ofl/delagothicone/DelaGothicOne-Regular.ttf"

# ASCII と、2 つのページの全文を対象にする
{ cat docs/index.html docs/en/index.html; printf '%s' ' !"#$%&()*+,-./0123456789:;=?@ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'; } > "$WORK/text.txt"

"$WORK/venv/bin/pyftsubset" "$WORK/font.ttf" \
  --text-file="$WORK/text.txt" \
  --layout-features='*' \
  --flavor=woff2 \
  --output-file=docs/assets/DelaGothicOne-subset.woff2

ls -la docs/assets/DelaGothicOne-subset.woff2
