#!/usr/bin/env bash
# 自己署名のコード署名証明書をログインキーチェーンに作る。
#
#   scripts/create-signing-cert.sh ["証明書の名前"]
#
# 毎回同じ証明書で署名すると、リビルドしてもアクセシビリティ権限が残る（ad-hoc 署名はビルドごとに変わる）。
# Gatekeeper に信頼されるわけではない。それには Developer ID と公証が必要。
#
# bundle.sh は "ClingCling Self-Signed" という名前の証明書を自動で使う。
# コード署名用に信頼する設定のため、macOS がログインパスワードを求める。
set -euo pipefail

NAME="${1:-ClingCling Self-Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -F "\"$NAME\"" >/dev/null; then
  echo "証明書 \"$NAME\" は既にあります。"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

# /usr/bin/openssl (LibreSSL) の PKCS#12 なら security import が受け付ける
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASSWORD="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout "pass:$PASSWORD"

# -T を付けると、codesign がビルドのたびにキーチェーンの確認を出さずに秘密鍵を使える
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
echo "証明書をコード署名用に信頼します（macOS がパスワードを求めます）…"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "\"$NAME\" を作成しました。bundle.sh が自動で使います。次のビルドの後に一度だけアクセシビリティ権限を許可し直してください。"
