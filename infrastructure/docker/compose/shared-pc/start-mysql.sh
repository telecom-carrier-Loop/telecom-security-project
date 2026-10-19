#!/usr/bin/env bash
set -Eeuo pipefail
# NTFS bind mounts do not guarantee Linux key ownership/mode. Copy only this
# server's certificate files into a container tmpfs, never the CA private key.
install -o mysql -g mysql -m 0644 /run/secrets/tls/ca.crt /run/mysql-tls/ca.crt
install -o mysql -g mysql -m 0644 /run/secrets/tls/server.crt /run/mysql-tls/server.crt
install -o mysql -g mysql -m 0600 /run/secrets/tls/server.key /run/mysql-tls/server.key
if [[ -f /run/secrets/tls/client.key ]]; then
    install -o mysql -g mysql -m 0644 /run/secrets/tls/client.crt /run/mysql-tls/client.crt
    install -o mysql -g mysql -m 0600 /run/secrets/tls/client.key /run/mysql-tls/client.key
fi
exec /usr/local/bin/docker-entrypoint.sh "$@"
