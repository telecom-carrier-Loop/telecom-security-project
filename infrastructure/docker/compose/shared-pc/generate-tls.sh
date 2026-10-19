#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
cd /material
[[ ! -e pki/ca.key && ! -e pki/ca.crt ]] || { echo 'Existing CA preserved; refusing regeneration' >&2; exit 2; }
mkdir -p pki pc1/tls pc2-transfer/tls
openssl req -x509 -newkey rsa:3072 -nodes -days 365 -sha256 \
  -keyout pki/ca.key -out pki/ca.crt -subj '/CN=Telecom Shared PC CA' \
  -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign'
issue() {
  local destination="$1" common_name="$2" usage="$3"
  openssl req -new -newkey rsa:2048 -nodes -keyout "$destination.key" \
    -out "$destination.csr" -subj "/CN=$common_name"
  printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=%s\nsubjectAltName=DNS:%s\n' \
    "$usage" "$common_name" > "$destination.ext"
  openssl x509 -req -in "$destination.csr" -CA pki/ca.crt -CAkey pki/ca.key \
    -CAcreateserial -out "$destination.crt" -days 90 -sha256 -extfile "$destination.ext"
}
issue pc1/tls/server mysql-primary.telecom.test serverAuth
issue pc2-transfer/tls/server mysql-replica.telecom.test serverAuth
issue pc2-transfer/tls/client telecom-pc2-replica clientAuth
cp pki/ca.crt pc1/tls/ca.crt
cp pki/ca.crt pc2-transfer/tls/ca.crt
openssl verify -CAfile pki/ca.crt pc1/tls/server.crt pc2-transfer/tls/server.crt pc2-transfer/tls/client.crt
