#!/usr/bin/env bash
# Nightly retention. Voicemail 30 days from deposit OR last save; CDRs 18 months.
# Greetings and recorded names are never touched: this is driven from
# vm_retention, which only ever contains message uuids.
set -euo pipefail

: "${PG_CONTAINER:=postgres18}"
: "${PG_USER:=freeswitch}"
: "${PG_DB:=freeswitch}"
: "${VM_DAYS:=30}"
: "${VM_GRACE_DAYS:=1}"
: "${CDR_MONTHS:=18}"

psql() { docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -qAt "$@"; }

# 1. track newly deposited messages
psql <<SQL
INSERT INTO vm_retention (message_uuid, extension_id, deposited_at, last_folder, retain_until)
SELECT m.uuid::uuid, e.id, to_timestamp(m.created_epoch), m.in_folder,
       to_timestamp(m.created_epoch) + interval '${VM_DAYS} days'
  FROM voicemail_msgs m
  JOIN domains d ON d.domain = m.domain
  JOIN extensions e ON e.domain_id = d.id AND e.extension = m.username
 WHERE m.uuid::uuid NOT IN (SELECT message_uuid FROM vm_retention)
ON CONFLICT (message_uuid) DO NOTHING;
SQL

# 2. renew anything moved to saved since the last run
psql <<SQL
UPDATE vm_retention r
   SET retain_until = now() + interval '${VM_DAYS} days',
       last_folder  = m.in_folder
  FROM voicemail_msgs m
 WHERE m.uuid::uuid = r.message_uuid
   AND m.in_folder = 'saved'
   AND r.last_folder <> 'saved';
SQL

# 3. delete expired messages through mod_voicemail so MWI counts stay correct
psql -c "SELECT m.domain, m.username, r.message_uuid
           FROM vm_retention r JOIN voicemail_msgs m ON m.uuid::uuid = r.message_uuid
          WHERE r.retain_until < now() - interval '${VM_GRACE_DAYS} days'" -F'|' \
| while IFS='|' read -r domain username uuid; do
    [ -z "${uuid:-}" ] && continue
    fs_cli -x "vm_fsdb_msg_delete ${domain} ${username} ${uuid}" >/dev/null
  done

# 4. drop rows for messages that no longer exist (expired above, or user-deleted)
psql <<SQL
DELETE FROM vm_retention r
 WHERE NOT EXISTS (SELECT 1 FROM voicemail_msgs m WHERE m.uuid::uuid = r.message_uuid);
SQL

# 5. CDRs
psql <<SQL
DELETE FROM cdrs
 WHERE start_epoch < extract(epoch FROM now() - interval '${CDR_MONTHS} months');
SQL
