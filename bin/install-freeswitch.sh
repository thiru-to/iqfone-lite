#!/usr/bin/env bash
# FreeSWITCH from source. The module selection below is the intent-carrying part; every enabled
# module needs its dev library in the apt list or the build dies mid-make.
# step-inputs: resources/freeswitch.service
# step-versions: FS_VERSION LIBKS_REF SOFIA_SIP_REF SPANDSP_REF
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export REPO_DIR

if [ -f "$REPO_DIR/lib/common.sh" ]; then
  # shellcheck disable=SC1090
  . "$REPO_DIR/lib/common.sh"
else
  info() {
    echo "==> $*"
  }

  ok() {
    echo "ok: $*"
  }

  warn() {
    echo "warn: $*" >&2
  }

  die() {
    echo "error: $*" >&2
    exit 1
  }

  require_root() {
    if [ "$(id -u)" -ne 0 ]; then
      die "This script must be run as root"
    fi
  }

  load_config() {
    local config_file="$REPO_DIR/secrets.env"
    [ -f "$config_file" ] || return 0
    set -a
    # shellcheck disable=SC1090
    . "$config_file"
    set +a
  }

  git_at_ref() {
    local target_dir="$1"
    local repo_url="$2"
    local ref="${3:-}"

    if [ -d "$target_dir/.git" ]; then
      git -C "$target_dir" fetch --all --tags --prune >/dev/null 2>&1 || true
      if [ -n "$ref" ]; then
        git -C "$target_dir" checkout "$ref" >/dev/null 2>&1 || true
      fi
      return 0
    fi

    if [ -e "$target_dir" ]; then
      rm -rf "$target_dir"
    fi

    git clone "$repo_url" "$target_dir" >/dev/null 2>&1 || true
    if [ -n "$ref" ] && [ -d "$target_dir/.git" ]; then
      git -C "$target_dir" checkout "$ref" >/dev/null 2>&1 || true
    fi
  }
fi

require_root
load_config

FS_VERSION="${1:-$FS_VERSION}"
FS_SOUND_RATES="${FS_SOUND_RATES:-8000 48000}"
BUILD_DIR="/usr/src"
PREFIX="/usr/local/freeswitch"
JOBS="$(nproc)"

info "Building FreeSWITCH $FS_VERSION with $JOBS jobs"

sudo apt -y update
sudo apt -y install htop curl git sngrep ca-certificates \
  gpg vim-tiny tcpdump rsyslog apt-transport-https gnupg2 lsb-release wget

sudo apt -y install \
  git build-essential automake autoconf wget libtool \
  libncurses-dev libjpeg-dev libsqlite3-dev libcurl4-openssl-dev \
  libpcre2-dev libspeexdsp-dev libspeex-dev libldns-dev libedit-dev \
  libssl-dev zlib1g-dev liblua5.2-dev libopus-dev libsndfile1-dev \
  libavformat-dev libswscale-dev libtool-bin libtiff-dev cmake uuid-dev \
  libpq-dev libshout3-dev libmp3lame-dev libmpg123-dev \
  libhiredis-dev

cd "$BUILD_DIR"
git_at_ref "$BUILD_DIR/libks"      https://github.com/signalwire/libks.git      "$LIBKS_REF"      || true
git_at_ref "$BUILD_DIR/spandsp"    https://github.com/freeswitch/spandsp.git    "$SPANDSP_REF"    || true
git_at_ref "$BUILD_DIR/freeswitch" https://github.com/signalwire/freeswitch.git "$FS_VERSION"     || true
git_at_ref "$BUILD_DIR/sofia-sip"  https://github.com/freeswitch/sofia-sip.git  "$SOFIA_SIP_REF"  || true

UNIT_TEMPLATE="$REPO_DIR/resources/freeswitch.service"
[ -f "$UNIT_TEMPLATE" ] || die "Missing $UNIT_TEMPLATE - is the repo checkout complete?"

cd "$BUILD_DIR/spandsp"

sudo ./bootstrap.sh
sudo ./configure
sudo make -j"$JOBS"
sudo make install

cd "$BUILD_DIR/libks"
sudo cmake .
sudo make -j"$JOBS"
sudo make install

cd "$BUILD_DIR/sofia-sip"
sudo ./bootstrap.sh
sudo ./configure --enable-debug
sudo make -j"$JOBS"
sudo make install

sudo ldconfig

cd "$BUILD_DIR/freeswitch"

# Upstream passes the Redis reply as a printf format string, so any cached value containing %
# comes back corrupted. Reachable from tenant-controlled data. Must stay patched.
HIREDIS_SRC="$BUILD_DIR/freeswitch/src/mod/applications/mod_hiredis/mod_hiredis.c"
if [ -f "$HIREDIS_SRC" ]; then
  if grep -q 'write_function(stream, response);' "$HIREDIS_SRC"; then
    sudo sed -i 's|write_function(stream, response);|write_function(stream, "%s", response);|' "$HIREDIS_SRC"
    ok "Patched mod_hiredis format-string bug"
  elif grep -q 'write_function(stream, "%s", response);' "$HIREDIS_SRC"; then
    ok "mod_hiredis format-string fix already present"
  else
    warn "mod_hiredis.c does not match either form - upstream may have changed it."
    warn "  Check that the Redis reply is not being used as a printf format string."
  fi
fi

sudo ./bootstrap.sh -j

FS_ENABLE_MODULES="
applications/mod_callcenter
applications/mod_cidlookup
applications/mod_hiredis
applications/mod_curl
applications/mod_easyroute
applications/mod_nibblebill
event_handlers/mod_fail2ban
formats/mod_shout
databases/mod_pgsql
xml_int/mod_xml_curl
"

FS_DISABLE_MODULES="
applications/mod_signalwire
applications/mod_av
endpoints/mod_skinny
endpoints/mod_verto
say/mod_say_es
say/mod_say_fr
xml_int/mod_xml_rpc
"

for m in $FS_ENABLE_MODULES; do
  if ! grep -qE "^#?${m}\$" modules.conf; then
    echo "ERROR: '$m' not found in modules.conf - the module path changed upstream" >&2
    exit 1
  fi
  sudo sed -i "s|^#${m}\$|${m}|" modules.conf
done

for m in $FS_DISABLE_MODULES; do
  if ! grep -qE "^#?${m}\$" modules.conf; then
    echo "ERROR: '$m' not found in modules.conf - the module path changed upstream" >&2
    exit 1
  fi
  sudo sed -i "s|^${m}\$|#${m}|" modules.conf
done

sudo ./configure -C \
  --disable-dependency-tracking --enable-debug --enable-core-pgsql-support \
  --disable-libvpx

sudo make -j"$JOBS"
sudo make install

for rate in $FS_SOUND_RATES; do
  sudo make "sounds-en-us-callie-${rate}-install" "sounds-music-${rate}-install"
done

sudo rm -rf "$PREFIX/conf"
sudo make config-minimal

if [ ! -f "$PREFIX/conf/freeswitch.xml" ]; then
  echo "ERROR: $PREFIX/conf/freeswitch.xml is missing - 'make config-minimal' did not complete" >&2
  exit 1
fi

FS_AUTOLOAD_CONF="$PREFIX/conf/autoload_configs/modules.conf.xml"
for m in $FS_DISABLE_MODULES; do
  mod_name="${m##*/}"
  grep -q "<load module=\"${mod_name}\"/>" "$FS_AUTOLOAD_CONF" || continue
  sudo sed -i "s|<load module=\"${mod_name}\"/>|<!-- <load module=\"${mod_name}\"/> -->|" \
    "$FS_AUTOLOAD_CONF"
  echo "Un-autoloaded '$mod_name' - it is not built"
done

FS_AUTOLOAD_ADD="mod_opus"
for mod_name in $FS_AUTOLOAD_ADD; do
  if [ ! -f "$PREFIX/mod/${mod_name}.so" ]; then
    echo "ERROR: ${mod_name}.so was not built but is required" >&2
    exit 1
  fi
  conf_name="${mod_name#mod_}.conf.xml"
  src_conf="$BUILD_DIR/freeswitch/conf/vanilla/autoload_configs/$conf_name"
  if [ -f "$src_conf" ] && [ ! -f "$PREFIX/conf/autoload_configs/$conf_name" ]; then
    sudo install -m 644 "$src_conf" "$PREFIX/conf/autoload_configs/$conf_name"
    echo "Installed $conf_name from the vanilla config"
  fi

  grep -q "<load module=\"${mod_name}\"/>" "$FS_AUTOLOAD_CONF" && continue
  sudo sed -i "s|<!-- Codec Interfaces -->|<!-- Codec Interfaces -->\n    <load module=\"${mod_name}\"/>|" \
    "$FS_AUTOLOAD_CONF"
  echo "Autoloaded '$mod_name'"
done

getent group freeswitch >/dev/null || sudo groupadd freeswitch
id -u freeswitch >/dev/null 2>&1 || sudo adduser --quiet --system  \
  --gecos 'FreeSWITCH open source softswitch' --ingroup freeswitch --disabled-password freeswitch

FS_ADMINS="${SUDO_USER:-${USER:-}}"
for admin_group in sudo admin; do
  members="$(getent group "$admin_group" | cut -d: -f4 | tr ',' ' ')" || members=""
  FS_ADMINS="$FS_ADMINS $members"
done
FS_ADMINS="$(echo "$FS_ADMINS" | tr ' ' '\n' | sort -u)"

# shellcheck disable=SC2086 # word splitting is intentional here
for u in $FS_ADMINS; do
  if [ "$u" = "root" ] || ! id -u "$u" >/dev/null 2>&1; then
    continue
  fi
  if id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx freeswitch; then
    continue
  fi
  sudo usermod -aG freeswitch "$u"
  echo "Added '$u' to the freeswitch group"
done

sudo ln -sf "$PREFIX/bin/fs_cli" /usr/bin/fs_cli
sudo ln -sf "$PREFIX/bin/freeswitch" /usr/sbin/freeswitch

sudo chown -R freeswitch:freeswitch "$PREFIX"
sudo chmod -R u+rwX,g+rwX,o+rX "$PREFIX"

sudo find "$PREFIX/conf" -type d -exec chmod g+s {} +

sudo ln -sfn "$PREFIX/conf" /etc/freeswitch

if [ ! -x "$PREFIX/bin/freeswitch" ]; then
  echo "ERROR: $PREFIX/bin/freeswitch is missing - 'make install' did not complete" >&2
  exit 1
fi

sudo sed "s|\${PREFIX}|$PREFIX|g" "$UNIT_TEMPLATE" \
  | sudo tee /etc/systemd/system/freeswitch.service >/dev/null

sudo systemctl daemon-reload
sudo systemctl enable freeswitch.service
sudo systemctl start freeswitch.service

echo
echo "FreeSWITCH $FS_VERSION installed to $PREFIX."
echo "  status : sudo systemctl status freeswitch"
echo "  console: fs_cli"
echo "  config : $PREFIX/conf (also linked as /etc/freeswitch)"
echo
echo "Members of the freeswitch group must log out and back in for it to take effect."
