> **Archived 2026-11-24:** superseded by the repos in [github.com/iQfone](https://github.com/iQfone). Read-only.

# iqfone-lite

Minimal hosted PBX. FreeSWITCH + PostgreSQL on a single Vultr instance. Inbound
calls reach exactly three terminations: softphone, voicemail, or call-forward.

Design and decisions: [`docs/plan.md`](docs/plan.md).

## Layout

```
etc/freeswitch/     FreeSWITCH config, deployed to /etc/freeswitch
etc/nftables.conf   host firewall
etc/fail2ban/       jail + filter
scripts/            Lua: directory auth and inbound routing
sql/                schema
bin/                deploy, backup, retention, monitoring checks
docs/plan.md        the build plan
```

## Secrets

Nothing secret is tracked. `etc/freeswitch/vars.xml` carries `CHANGEME`
placeholders and includes `vars.local.xml`, which is gitignored and holds the
real values — copy `vars.local.xml.example` to start. `secrets.example` is the
full inventory.

## Rebuild from scratch

This is the recovery procedure (P13). **Rehearse it on a scratch instance before
launch and record the elapsed time — that is the real RTO, not an estimate.**

1. Debian 12 on Vultr, dedicated-CPU plan preferred. Attach the **Reserved IP**
   before configuring BulkVS — recovery is then a reassignment, not a carrier
   ticket.
2. Firewall: `cp etc/nftables.conf /etc/nftables.conf && systemctl enable --now nftables`
3. Postgres:
   ```
   docker run --name postgres18 -e POSTGRES_PASSWORD=... \
     -p 127.0.0.1:5432:5432 -v pgdata18:/var/lib/postgresql \
     --restart unless-stopped -d postgres:18
   ```
   The `127.0.0.1` prefix is not optional — Docker publishes past the firewall.
4. FreeSWITCH from the SignalWire repo (needs a personal access token):
   ```
   curl -sSL https://freeswitch.org/fsget | bash -s $TOKEN release
   apt -y install freeswitch freeswitch-conf-minimal ...
   ```
5. Schema: `docker exec -i postgres18 psql -U freeswitch -d freeswitch < sql/001_init.sql`
6. Restore the latest backup if this is a recovery, not a first build.
7. Copy `vars.local.xml`, `/etc/msmtprc` and `secrets.env` by hand.
8. `TARGET=root@host bin/deploy.sh --restart`
9. Verify against the checklist in `docs/plan.md`.

## Day-to-day

```
TARGET=root@host bin/deploy.sh            # config change, reloadxml, no dropped calls
TARGET=root@host bin/deploy.sh --restart  # needed for module or TLS changes only
```

`reloadxml` is free. A sofia profile `restart` drops every registration on that
profile — schedule it.

## Cron

```
15 3 * * *   BACKUP_DIR=... GPG_RECIPIENT=... /usr/local/bin/backup.sh
30 3 * * *   /usr/local/bin/retention.sh
*/15 * * * * ALERT_TO=... /usr/local/bin/checks.sh
```

## Not yet built

- Provisioning API and webhook service (P12)
- Custom prompts: `custom/user-not-available.wav`,
  `custom/account-balance-low.wav`, `custom/e911-registration-required.wav`
  (8 kHz mono WAV under the sounds directory)
