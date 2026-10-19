#!/usr/bin/env bash
# Linux shared-PC template. No passwords on argv; no automatic backup deletion.
set -Eeuo pipefail
umask 077
: "${MYSQL_BACKUP_CNF:?Path to a protected MySQL client option file}"
: "${BACKUP_DIR:?Absolute backup destination on a separate protected medium}"
: "${GPG_RECIPIENT:?Verified full encryption-key fingerprint}"
DB_NAME="${DB_NAME:-telecom}"
[[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || { echo 'Invalid DB_NAME' >&2; exit 2; }
[[ "$BACKUP_DIR" = /* && "$BACKUP_DIR" != / ]] || { echo 'Use a specific absolute BACKUP_DIR' >&2; exit 2; }
[[ "$GPG_RECIPIENT" =~ ^([A-Fa-f0-9]{40}|[A-Fa-f0-9]{64})$ ]] || { echo 'Use the verified full GPG fingerprint' >&2; exit 2; }
[[ -f "$MYSQL_BACKUP_CNF" ]] || { echo 'Missing client configuration' >&2; exit 2; }
mode="$(stat -c '%a' "$MYSQL_BACKUP_CNF")"
(( (8#$mode & 077) == 0 )) || { echo 'Client configuration must not be group/world-readable' >&2; exit 2; }
for command in mysqldump gzip gpg sha256sum flock; do command -v "$command" >/dev/null; done
mkdir -p -- "$BACKUP_DIR"
exec 9>"$BACKUP_DIR/.backup.lock"
flock -n 9 || { echo 'Another backup is running' >&2; exit 3; }
name="${DB_NAME}-$(date -u +%Y%m%dT%H%M%SZ).sql.gz.gpg"
target="$BACKUP_DIR/$name"
[[ ! -e "$target" ]] || { echo 'Backup destination already exists' >&2; exit 3; }
partial="$(mktemp "$BACKUP_DIR/.backup-partial.XXXXXX")"
trap 'if [[ -n "${partial:-}" && -f "$partial" ]]; then rm -f -- "$partial"; fi' EXIT
# No --databases: restore may select a separate empty test DB.
# set-gtid-purged=OFF is for logical application-data recovery, not Replica provisioning.
mysqldump --defaults-extra-file="$MYSQL_BACKUP_CNF" \
    --single-transaction --no-tablespaces --set-gtid-purged=OFF \
    --routines --events --triggers --hex-blob "$DB_NAME" \
    | gzip -c | gpg --batch --yes --encrypt --recipient "$GPG_RECIPIENT" --output "$partial"
[[ -s "$partial" ]] || { echo 'Empty encrypted backup' >&2; exit 4; }
mv -- "$partial" "$target"
partial=''
(cd -- "$BACKUP_DIR" && sha256sum -- "$name" > "$name.sha256")
printf '{"event_type":"infra.backup.succeeded","file":"%s","timestamp":"%s"}\n' "$name" "$(date -u +%FT%TZ)"
