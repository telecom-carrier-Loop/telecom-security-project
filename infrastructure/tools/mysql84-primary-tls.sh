#!/bin/sh
set -eu

mode=$1
data=$2
work=$3
case "$mode" in
  generate)
    test ! -e "$work"
    test -s "$data/ca.pem"
    test -s "$data/ca-key.pem"
    test -s "$data/server-cert.pem"
    test -s "$data/server-key.pem"
    umask 077
    mkdir "$work"
    cp -p "$data/server-cert.pem" "$work/original-server-cert.pem"
    cp -p "$data/server-key.pem" "$work/original-server-key.pem"
    cp "$data/ca.pem" "$work/ca.pem"
    printf '%s\n' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature,keyEncipherment' 'extendedKeyUsage=serverAuth' 'subjectAltName=IP:192.168.3.18,IP:127.0.0.1,DNS:localhost,DNS:flask_mysql' > "$work/server.ext"
    printf '%s\n' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature,keyEncipherment' 'extendedKeyUsage=clientAuth' > "$work/client.ext"
    openssl req -new -newkey rsa:3072 -nodes -sha256 -subj /CN=192.168.3.18 -keyout "$work/server-key.pem" -out "$work/server.csr"
    openssl x509 -req -in "$work/server.csr" -CA "$data/ca.pem" -CAkey "$data/ca-key.pem" -CAserial "$work/ca.srl" -CAcreateserial -days 365 -sha256 -extfile "$work/server.ext" -out "$work/server-cert.pem"
    openssl req -new -newkey rsa:3072 -nodes -sha256 -subj /CN=loop-pc2-replica -keyout "$work/client-key.pem" -out "$work/client.csr"
    openssl x509 -req -in "$work/client.csr" -CA "$data/ca.pem" -CAkey "$data/ca-key.pem" -CAserial "$work/ca.srl" -days 365 -sha256 -extfile "$work/client.ext" -out "$work/client-cert.pem"
    openssl verify -CAfile "$data/ca.pem" -purpose sslserver -verify_ip 192.168.3.18 "$work/server-cert.pem"
    openssl verify -CAfile "$data/ca.pem" -purpose sslclient "$work/client-cert.pem"
    ;;
  install)
    test -s "$work/original-server-cert.pem"
    test -s "$work/original-server-key.pem"
    openssl verify -CAfile "$data/ca.pem" -purpose sslserver -verify_ip 192.168.3.18 "$work/server-cert.pem"
    cp "$work/server-cert.pem" "$data/server-cert.pem"
    cp "$work/server-key.pem" "$data/server-key.pem"
    chown mysql:mysql "$data/server-cert.pem" "$data/server-key.pem"
    chmod 600 "$data/server-cert.pem" "$data/server-key.pem"
    ;;
  *) echo 'Unknown TLS action' >&2; exit 1 ;;
esac
