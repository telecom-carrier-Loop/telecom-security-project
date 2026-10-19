#!/usr/bin/env bash
# Restore ONLY into a new, empty database whose name starts with telecom_restore_test.
set -Eeuo pipefail
umask 077
: "${MYSQL_RESTORE_CNF:?Protected client option file for an isolated restore server}"
: "${RESTORE_FILE:?Full path to an encrypted backup}"
RESTORE_DB="${RESTORE_DB:-telecom_restore_test}"
[[ "$RESTORE_DB" =~ ^telecom_restore_test(_[A-Za-z0-9]+)*$ ]] || { echo 'Refusing non-test database target' >&2; exit 2; }
[[ -f "$MYSQL_RESTORE_CNF" && -f "$RESTORE_FILE" && -f "$RESTORE_FILE.sha256" ]] || { echo 'Missing protected config/backup/checksum' >&2; exit 2; }
mode="$(stat -c '%a' "$MYSQL_RESTORE_CNF")"
(( (8#$mode & 077) == 0 )) || { echo 'Protect the client configuration first' >&2; exit 2; }
directory="$(dirname -- "$RESTORE_FILE")"
checksum="$(basename -- "$RESTORE_FILE").sha256"
(cd -- "$directory" && sha256sum --check -- "$checksum")
count="$(mysql --defaults-extra-file="$MYSQL_RESTORE_CNF" --batch --skip-column-names \
    --execute="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$RESTORE_DB'")"
[[ "$count" == 0 ]] || { echo 'Restore target is not empty; nothing dropped' >&2; exit 3; }
mysql --defaults-extra-file="$MYSQL_RESTORE_CNF" --execute="CREATE DATABASE IF NOT EXISTS \`$RESTORE_DB\` CHARACTER SET utf8mb4"
gpg --batch --decrypt "$RESTORE_FILE" | gzip -dc \
    | mysql --defaults-extra-file="$MYSQL_RESTORE_CNF" "$RESTORE_DB"
printf 'Restored into %s. Compare schema, row counts, constraints and synthetic transactions before declaring success.\n' "$RESTORE_DB"
