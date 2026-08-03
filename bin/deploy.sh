#!/usr/bin/env bash
# Push config and scripts to the box. This is the P13 runbook, executable.
# Secrets (vars.local.xml, msmtprc, secrets.env) are deployed separately by hand.
set -euo pipefail

: "${TARGET:?usage: TARGET=root@host bin/deploy.sh [--restart]}"
: "${SCRIPT_DIR:=/usr/share/freeswitch/scripts}"

repo="$(cd "$(dirname "$0")/.." && pwd)"

command -v xmllint >/dev/null || { echo "xmllint required (libxml2-utils)" >&2; exit 1; }
find "$repo/etc/freeswitch" -name '*.xml' -print0 \
  | xargs -0 xmllint --noout --nonet
echo "xml ok"

rsync -a --delete \
  --exclude 'vars.local.xml' \
  --exclude 'vars.local.xml.example' \
  --exclude 'tls/' \
  "$repo/etc/freeswitch/" "$TARGET:/etc/freeswitch/"

rsync -a "$repo/scripts/" "$TARGET:$SCRIPT_DIR/"
rsync -a "$repo/bin/" "$TARGET:/usr/local/bin/"

ssh "$TARGET" "luac -p $SCRIPT_DIR/*.lua"

if [ "${1:-}" = "--restart" ]; then
  ssh "$TARGET" "systemctl restart freeswitch"
else
  # reloadxml does not drop registrations; a profile restart does
  ssh "$TARGET" "fs_cli -x 'reloadxml'"
fi
