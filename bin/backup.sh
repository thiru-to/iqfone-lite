#!/usr/bin/env bash
# Nightly encrypted pg_dump. Contains SIP credentials, voicemail PINs and CPNI.
set -euo pipefail

: "${BACKUP_DIR:=/var/backups/iqfone}"
: "${GPG_RECIPIENT:?set GPG_RECIPIENT to the backup encryption key id}"
: "${PG_CONTAINER:=postgres18}"
: "${PG_USER:=freeswitch}"
: "${PG_DB:=freeswitch}"
: "${KEEP_DAYS:=35}"

mkdir -p "$BACKUP_DIR"
out="$BACKUP_DIR/freeswitch-$(date -u +%Y%m%dT%H%M%SZ).sql.gz.gpg"

docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" \
  | gzip \
  | gpg --batch --yes --encrypt --recipient "$GPG_RECIPIENT" --output "$out"

chmod 600 "$out"

# voicemail audio is deliberately not backed up: 30-day transient data,
# and the notification email already carries a copy

find "$BACKUP_DIR" -name 'freeswitch-*.sql.gz.gpg' -mtime "+$KEEP_DAYS" -delete

echo "$out"
