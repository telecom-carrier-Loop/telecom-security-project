#!/bin/sh
set -eu
PATH=/usr/bin:/bin:$PATH
export PATH
root=$1
tool=$2
mkdir "$root/data"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 2 -subj /CN=Loop-Test-CA -addext basicConstraints=critical,CA:TRUE -keyout "$root/data/ca-key.pem" -out "$root/data/ca.pem"
printf '%s\n' original-cert > "$root/data/server-cert.pem"
printf '%s\n' original-key > "$root/data/server-key.pem"
sh "$tool" generate "$root/data" "$root/work"
grep -qx original-cert "$root/data/server-cert.pem"
grep -qx original-key "$root/data/server-key.pem"
test ! -e "$root/work/ca-key.pem"
openssl verify -CAfile "$root/data/ca.pem" -purpose sslserver -verify_ip 127.0.0.1 "$root/work/server-cert.pem"
if openssl verify -CAfile "$root/data/ca.pem" -verify_ip 192.168.3.99 "$root/work/server-cert.pem"; then exit 1; fi
if openssl verify -CAfile "$root/data/ca.pem" -purpose sslserver "$root/work/client-cert.pem"; then exit 1; fi
if sh "$tool" generate "$root/data" "$root/work"; then exit 1; fi
echo 'PASS: certificate chain, PC1 IP, loopback IP, client purpose, wrong IP rejection, original preservation and rerun refusal'
