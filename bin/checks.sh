#!/usr/bin/env bash
# On-box threshold checks (P14). Emails on breach; the external uptime service
# owns anything that must page when the box itself is down.
# Every alert names the action, not just the condition.
set -uo pipefail

: "${ALERT_TO:?set ALERT_TO}"
: "${PG_CONTAINER:=postgres18}"
: "${PG_USER:=freeswitch}"
: "${PG_DB:=freeswitch}"
: "${BACKUP_DIR:=/var/backups/iqfone}"
: "${TLS_CERT:=/etc/freeswitch/tls/agent.pem}"
: "${CERT_MIN_DAYS:=21}"
: "${DISK_MAX_PCT:=80}"
: "${STEAL_MAX_PCT:=5}"
: "${BACKUP_MAX_HOURS:=36}"

alerts=()
add() { alerts+=("$1"); }

psql() { docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -qAt "$@"; }

# TLS cert: silent renewal failure breaks every client at once on day 90
if [ -f "$TLS_CERT" ]; then
  end=$(openssl x509 -enddate -noout -in "$TLS_CERT" | cut -d= -f2)
  days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
  [ "$days" -lt "$CERT_MIN_DAYS" ] && \
    add "TLS cert expires in ${days}d. Run certbot renew, then restart the internal profile in a quiet window."
else
  add "TLS cert missing at $TLS_CERT. Softphones cannot register over TLS."
fi

# Backup age: a backup that quietly stopped is worse than none
newest=$(find "$BACKUP_DIR" -name '*.sql.gz.gpg' -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
if [ -z "${newest:-}" ]; then
  add "No backup found in $BACKUP_DIR. Run bin/backup.sh and check the cron entry."
else
  age=$(( ( $(date +%s) - ${newest%.*} ) / 3600 ))
  [ "$age" -gt "$BACKUP_MAX_HOURS" ] && \
    add "Newest backup is ${age}h old. Run bin/backup.sh and check the cron entry."
fi

# Disk
pct=$(df --output=pcent / | tail -1 | tr -dc '0-9')
[ "$pct" -gt "$DISK_MAX_PCT" ] && \
  add "Disk at ${pct}%. Run bin/retention.sh, or resize the instance."

# CPU steal: the shared-vCPU assumption quietly not holding shows up as bad audio
steal=$(vmstat 1 2 | tail -1 | awk '{print $NF}')
[ "${steal:-0}" -gt "$STEAL_MAX_PCT" ] && \
  add "CPU steal at ${steal}%. Audio quality complaints are likely this, not the network. Consider a dedicated-CPU plan."

# FreeSWITCH liveness and trunk
if ! fs_cli -x status >/dev/null 2>&1; then
  add "FreeSWITCH is not answering on ESL. Check systemctl status freeswitch."
else
  fs_cli -x "sofia status gateway bulkvs" 2>/dev/null | grep -qi 'state.*\(REGED\|NOREG\|UP\)' || \
    add "BulkVS gateway is not up. No calls in or out. Check sofia status gateway bulkvs."
fi

# DIDs stuck pending: customer is paying and cannot call out
stuck=$(psql -c "SELECT count(*) FROM dids WHERE e911_status = 'pending' AND e911_updated_at < now() - interval '48 hours'" 2>/dev/null)
[ "${stuck:-0}" -gt 0 ] && \
  add "${stuck} DID(s) stuck in e911 pending >48h. Address validation likely failed; check BulkVS and re-submit."

# Retention job ran
stale=$(psql -c "SELECT count(*) FROM vm_retention WHERE retain_until < now() - interval '2 days'" 2>/dev/null)
[ "${stale:-0}" -gt 0 ] && \
  add "${stale} voicemail(s) past retention. bin/retention.sh has not run successfully."

if [ ${#alerts[@]} -gt 0 ]; then
  printf '%s\n\n' "${alerts[@]}" \
    | mail -s "iqfone: ${#alerts[@]} check(s) failing on $(hostname)" "$ALERT_TO"
  printf '%s\n' "${alerts[@]}"
  exit 1
fi
