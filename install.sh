#!/bin/bash
# Automated setup for ilo4-fan-quiet: permanently quiet fans on HP ProLiant
# servers running the patched iLO4 firmware from kendallgoto/ilo4_unlock.
#
# Interactive:      sudo ./install.sh
# Non-interactive:  ILO_IP=10.0.0.5 ILO_USER=fanctl ILO_PASS=secret sudo -E ./install.sh
#
# Optional env: FAN_MAX (default 32), FAN_COUNT (default 6),
#               CREATE_ILO_USER=yes (create the iLO user via hponcfg),
#               SUDOERS_USER=<name> (grant passwordless sudo for the TUI)
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/CK5515/ilo4-fan-quiet/main"
FILES=(ilo-fan-quiet ilo-fan-tui systemd/ilo-fan-quiet.service systemd/ilo-fan-quiet.timer)

[ "$EUID" -eq 0 ] || { echo "Please run as root: sudo ./install.sh" >&2; exit 1; }

for dep in sshpass ssh ping systemctl; do
  command -v "$dep" >/dev/null || { echo "Missing dependency: $dep (apt install sshpass openssh-client iputils-ping)" >&2; exit 1; }
done
command -v python3 >/dev/null || echo "WARNING: python3 not found - the TUI will not work" >&2
command -v ipmitool >/dev/null || echo "WARNING: ipmitool not found - the TUI's fan/temp readouts need it (apt install ipmitool)" >&2

# Locate payload files: next to this script, or download (curl | bash mode).
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd)"
if [ ! -f "$SRC/ilo-fan-quiet" ]; then
  SRC=$(mktemp -d)
  echo "Fetching files from $REPO_RAW ..."
  for f in "${FILES[@]}"; do
    mkdir -p "$SRC/$(dirname "$f")"
    curl -fsSL "$REPO_RAW/$f" -o "$SRC/$f"
  done
fi

ask() { # ask <prompt> <varname> [default] [silent]
  local prompt=$1 var=$2 def=${3:-} silent=${4:-}
  if [ -n "${!var:-}" ]; then return; fi
  local flags=-r; [ "$silent" = silent ] && flags=-rs
  read $flags -p "$prompt${def:+ [$def]}: " "$var" < /dev/tty
  [ "$silent" = silent ] && echo
  [ -n "${!var}" ] || printf -v "$var" '%s' "$def"
}

ask "iLO IP address" ILO_IP
ask "iLO SSH username" ILO_USER fanctl

if [ -z "${ILO_PASS:-}" ] && [ "${CREATE_ILO_USER:-}" != yes ] && command -v hponcfg >/dev/null; then
  read -r -p "Create iLO user '$ILO_USER' automatically via hponcfg? [y/N]: " yn < /dev/tty
  [[ ${yn,,} == y* ]] && CREATE_ILO_USER=yes
fi

if [ "${CREATE_ILO_USER:-}" = yes ]; then
  ILO_PASS=${ILO_PASS:-$(openssl rand -hex 12)}
  tmp=$(mktemp)
  cat > "$tmp" <<EOF
<RIBCL VERSION="2.0">
 <LOGIN USER_LOGIN="Administrator" PASSWORD="unused">
  <USER_INFO MODE="write">
   <ADD_USER USER_NAME="$ILO_USER" USER_LOGIN="$ILO_USER" PASSWORD="$ILO_PASS">
    <ADMIN_PRIV value="Y"/>
    <CONFIG_ILO_PRIV value="Y"/>
   </ADD_USER>
  </USER_INFO>
 </LOGIN>
</RIBCL>
EOF
  hponcfg -f "$tmp" >/dev/null && echo "iLO user '$ILO_USER' created."
  rm -f "$tmp"
else
  ask "iLO password for $ILO_USER" ILO_PASS "" silent
fi

ask "Fan cap, 0-255 (32 = ~12.5%)" FAN_MAX 32
ask "Number of fans" FAN_COUNT 6

echo "Installing files ..."
install -m 644 /dev/stdin /etc/default/ilo-fan <<EOF
ILO_IP=$ILO_IP
FAN_COUNT=$FAN_COUNT
EOF
install -m 600 /dev/stdin /etc/ilo-fanctl.conf <<EOF
ILO_USER=$ILO_USER
ILO_PASS=$ILO_PASS
EOF
echo "$FAN_MAX" | install -m 644 /dev/stdin /etc/ilo-fan-max

install -m 755 "$SRC/ilo-fan-quiet" /usr/local/sbin/ilo-fan-quiet
install -m 755 "$SRC/ilo-fan-tui" /usr/local/bin/ilo-fan-tui
install -m 644 "$SRC/systemd/ilo-fan-quiet.service" /etc/systemd/system/
install -m 644 "$SRC/systemd/ilo-fan-quiet.timer" /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now ilo-fan-quiet.timer >/dev/null

# Passwordless sudo so the TUI works without root.
TUI_USER=${SUDOERS_USER:-${SUDO_USER:-}}
if [ -n "$TUI_USER" ] && [ ! -f /etc/sudoers.d/ilo-fans ]; then
  read -r -p "Allow user '$TUI_USER' to run the TUI without a sudo password? [Y/n]: " yn < /dev/tty
  if [[ -z $yn || ${yn,,} == y* ]]; then
    echo "$TUI_USER ALL=(ALL) NOPASSWD: /usr/bin/ipmitool, /usr/bin/systemctl start ilo-fan-quiet.service, /usr/bin/install -m 644 -o root -g root * /etc/ilo-fan-max" \
      > /etc/sudoers.d/ilo-fans
    chmod 440 /etc/sudoers.d/ilo-fans
  fi
fi

echo "Applying fan caps now ..."
if systemctl start ilo-fan-quiet.service; then
  echo
  echo "Done. Fans are capped at $FAN_MAX/255. The systemd timer reapplies the"
  echo "cap at boot and every 10 minutes, so it survives iLO resets."
  echo "Run 'ilo-fan-tui' to monitor temps and adjust the cap."
else
  echo "Setup complete, but the first apply failed - check that the iLO at"
  echo "$ILO_IP is reachable and 'systemctl status ilo-fan-quiet' for details."
fi
