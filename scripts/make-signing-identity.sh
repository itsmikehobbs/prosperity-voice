#!/bin/bash
# Creates a self-signed code-signing identity in a project-local keychain (.signing/).
# A stable signature means macOS keeps the Microphone and Accessibility permissions across rebuilds.
# It does not touch the login keychain or the keychain search list.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .signing && cd .signing
[ -f pv.keychain-db ] && { echo "Signing identity already exists."; exit 0; }
cat > cert.cnf <<'CNF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Prosperity Voice Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 7300 -config cert.cnf
openssl rand -hex 16 > keychain-password
chmod 600 keychain-password key.pem
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:pv
PW=$(cat keychain-password)
security create-keychain -p "$PW" "$PWD/pv.keychain-db"
security set-keychain-settings "$PWD/pv.keychain-db"
security unlock-keychain -p "$PW" "$PWD/pv.keychain-db"
security import id.p12 -k "$PWD/pv.keychain-db" -P pv -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$PWD/pv.keychain-db" >/dev/null
echo "Created signing identity."
