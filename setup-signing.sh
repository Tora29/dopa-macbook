#!/bin/zsh
# DopaPachinko 専用の自己署名コード署名証明書をログインキーチェーンに作る（1回だけ実行）
# 削除したいときは「キーチェーンアクセス」で「DopaPachinko Dev」を消す
set -euo pipefail

NAME="DopaPachinko Dev"
if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "すでに「$NAME」があります"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

cat > cfg.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cfg.cnf 2>/dev/null
PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" -out id.p12 -passout "pass:$PASS" 2>/dev/null
# codesign だけがこの鍵を使えるようにして取り込む
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P "$PASS" -T /usr/bin/codesign

security find-identity -p codesigning | grep "$NAME" && echo "作成しました: $NAME"
