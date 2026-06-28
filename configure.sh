#!/bin/bash
# Interactive front end for this installer. Runs on YOUR OWN machine,
# never on the target box itself -- it just asks a handful of
# questions once, then either runs ansible-playbook directly against a
# host you're already SSH-reachable to (Method 1), or writes out a
# fully filled-in bootstrap.sh for you to paste into a cloud
# provider's startup-script field before a droplet even exists
# (Method 2). Either way, the target never has to answer a prompt
# itself -- by the time anything runs unattended, every answer is
# already baked in.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ask() {
  # ask "Prompt text" "default value" -> echoes the answer
  local prompt="$1" default="${2:-}" reply
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " reply
    echo "${reply:-$default}"
  else
    read -r -p "$prompt: " reply
    echo "$reply"
  fi
}

confirm() {
  # confirm "Prompt text" -> 0 (yes) or 1 (no), defaults to no
  local prompt="$1" reply
  read -r -p "$prompt [y/N]: " reply
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

echo "=== Rivolution unified installer setup ==="
echo

echo "Method 1: SSH into a box that's already running and reachable."
echo "Method 2: generate a bootstrap.sh to paste into a cloud provider's"
echo "          startup-script field before the box even exists."
echo
method="$(ask "Method (1 or 2)" "1")"

install_mode="$(ask "Install mode (standalone, server, or client)" "standalone")"
case "$install_mode" in
  standalone|server|client) ;;
  *) echo "Unrecognized install mode '$install_mode' -- must be standalone, server, or client." >&2; exit 1 ;;
esac

build_user="$(ask "Build user" "rd")"

remote_mysql_host="" remote_mysql_user="" remote_mysql_database="" remote_mysql_password="" remote_nfs_host=""
if [ "$install_mode" = "client" ]; then
  echo
  echo "Client mode points at a remote database and a remote NFS audio store instead of provisioning either locally."
  remote_mysql_host="$(ask "Remote MySQL/MariaDB host")"
  remote_mysql_user="$(ask "Remote MySQL user" "rduser")"
  remote_mysql_database="$(ask "Remote MySQL database" "Rivendell")"
  read -r -s -p "Remote MySQL password: " remote_mysql_password; echo
  remote_nfs_host="$(ask "Remote NFS host")"
fi

echo
advanced_mode="no"
if confirm "Enable advanced mode (Icecast/Liquidsoap/VLC/Stereo Tool configs + seed database)?"; then
  advanced_mode="yes"
fi

security_hardening="no"
harden_external_ip="" harden_lan_subnet=""
if confirm "Enable security hardening (firewall + SSH key-only login)?"; then
  security_hardening="yes"
  harden_external_ip="$(ask "External IP to allow through the firewall (blank to skip)")"
  harden_lan_subnet="$(ask "LAN subnet to allow, e.g. 192.168.1.0/24 (blank to skip)")"
fi

# Advanced mode's seed data is keyed to a host literally named "onair"
# -- enforced here too (not just by the playbook's own assertion) so a
# mismatch is caught before anything runs, not partway through.
hostname_default="onair"
if [ "$advanced_mode" = "yes" ]; then
  echo
  echo "Advanced mode requires the Rivolution hostname to be exactly 'onair' -- its seed data is keyed to that host name."
  hostname="$(ask "Rivolution hostname" "$hostname_default")"
  if [ "$hostname" != "onair" ]; then
    echo "Error: advanced mode requires hostname 'onair', got '$hostname'." >&2
    exit 1
  fi
else
  hostname="$(ask "Rivolution hostname" "$hostname_default")"
fi

if [ "$advanced_mode" = "yes" ]; then
  echo
  echo "=== Advanced mode disclaimer ==="
  echo "This software is provided AS IS, with absolutely no warranty."
  echo "Advanced mode will REPLACE the existing Rivendell database with a seed dataset on first run."
  echo "A backup of the existing database is taken automatically first, but make sure you also have your own backup before proceeding if this matters to you."
  if ! confirm "Continue with advanced mode?"; then
    echo "Aborted."
    exit 1
  fi
fi

extra_vars=(-e "rivolution_install_mode=$install_mode" -e "rivolution_user=$build_user" -e "rivolution_hostname=$hostname")
[ "$advanced_mode" = "yes" ] && extra_vars+=(-e "rivolution_advanced_broadcast_config=true")
[ "$security_hardening" = "yes" ] && extra_vars+=(-e "rivolution_harden_security=true")
[ -n "$harden_external_ip" ] && extra_vars+=(-e "rivolution_harden_external_ip=$harden_external_ip")
[ -n "$harden_lan_subnet" ] && extra_vars+=(-e "rivolution_harden_lan_subnet=$harden_lan_subnet")
[ -n "$remote_mysql_host" ] && extra_vars+=(-e "rivolution_remote_mysql_host=$remote_mysql_host")
[ -n "$remote_mysql_user" ] && extra_vars+=(-e "rivolution_remote_mysql_user=$remote_mysql_user")
[ -n "$remote_mysql_database" ] && extra_vars+=(-e "rivolution_remote_mysql_database=$remote_mysql_database")
[ -n "$remote_nfs_host" ] && extra_vars+=(-e "rivolution_remote_nfs_host=$remote_nfs_host")

remote_mysql_password_path=""
cleanup() { [ -n "$remote_mysql_password_path" ] && rm -f "$remote_mysql_password_path"; return 0; }
trap cleanup EXIT
if [ -n "$remote_mysql_password" ]; then
  remote_mysql_password_path="$(mktemp)"
  chmod 600 "$remote_mysql_password_path"
  printf '%s\n' "$remote_mysql_password" > "$remote_mysql_password_path"
  extra_vars+=(-e "rivolution_remote_mysql_password_path=$remote_mysql_password_path")
fi

if [ "$method" = "1" ]; then
  echo
  target_host="$(ask "Target host (IP or hostname), already SSH-reachable")"
  target_user="$(ask "SSH user on the target (root, or any sudo-capable account)" "root")"
  echo
  echo "Running: ansible-playbook -i \"$target_host,\" -u \"$target_user\" site.yml ..."
  cd "$SCRIPT_DIR"
  ansible-galaxy collection install -r requirements.yml
  ansible-playbook -i "$target_host," -u "$target_user" site.yml "${extra_vars[@]}"
else
  out_file="$SCRIPT_DIR/bootstrap-generated.sh"
  {
    echo '#!/bin/bash'
    echo "# Generated by configure.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ) -- paste this whole block into your"
    echo "# cloud provider's startup-script field, or run it as root on a fresh box."
    echo 'set -euo pipefail'
    echo
    echo 'INSTALLER_REPO="https://github.com/anjeleno/rivendell-golden-ansible.git"'
    echo "RIVOLUTION_HOSTNAME=\"$hostname\""
    echo "RIVOLUTION_INSTALL_MODE=\"$install_mode\""
    echo "RIVOLUTION_REMOTE_MYSQL_HOST=\"$remote_mysql_host\""
    echo "RIVOLUTION_REMOTE_MYSQL_USER=\"$remote_mysql_user\""
    echo "RIVOLUTION_REMOTE_MYSQL_DATABASE=\"$remote_mysql_database\""
    echo "RIVOLUTION_REMOTE_MYSQL_PASSWORD=\"$remote_mysql_password\""
    echo "RIVOLUTION_REMOTE_NFS_HOST=\"$remote_nfs_host\""
    echo
    echo 'apt-get update'
    echo 'apt-get install -y --no-install-recommends git ansible'
    echo
    echo 'extra_vars=()'
    echo 'cleanup_paths=()'
    echo 'cleanup() { rm -f "${cleanup_paths[@]}"; }'
    echo 'trap cleanup EXIT'
    echo '[ -n "$RIVOLUTION_HOSTNAME" ] && extra_vars+=(-e "rivolution_hostname=$RIVOLUTION_HOSTNAME")'
    echo '[ -n "$RIVOLUTION_INSTALL_MODE" ] && extra_vars+=(-e "rivolution_install_mode=$RIVOLUTION_INSTALL_MODE")'
    echo "extra_vars+=(-e \"rivolution_user=$build_user\")"
    [ "$advanced_mode" = "yes" ] && echo 'extra_vars+=(-e "rivolution_advanced_broadcast_config=true")'
    [ "$security_hardening" = "yes" ] && echo 'extra_vars+=(-e "rivolution_harden_security=true")'
    [ -n "$harden_external_ip" ] && echo "extra_vars+=(-e \"rivolution_harden_external_ip=$harden_external_ip\")"
    [ -n "$harden_lan_subnet" ] && echo "extra_vars+=(-e \"rivolution_harden_lan_subnet=$harden_lan_subnet\")"
    echo '[ -n "$RIVOLUTION_REMOTE_MYSQL_HOST" ] && extra_vars+=(-e "rivolution_remote_mysql_host=$RIVOLUTION_REMOTE_MYSQL_HOST")'
    echo '[ -n "$RIVOLUTION_REMOTE_MYSQL_USER" ] && extra_vars+=(-e "rivolution_remote_mysql_user=$RIVOLUTION_REMOTE_MYSQL_USER")'
    echo '[ -n "$RIVOLUTION_REMOTE_MYSQL_DATABASE" ] && extra_vars+=(-e "rivolution_remote_mysql_database=$RIVOLUTION_REMOTE_MYSQL_DATABASE")'
    echo 'if [ -n "$RIVOLUTION_REMOTE_MYSQL_PASSWORD" ]; then'
    echo '  mysql_password_path="$(mktemp)"'
    echo '  chmod 600 "$mysql_password_path"'
    echo '  printf '"'"'%s\n'"'"' "$RIVOLUTION_REMOTE_MYSQL_PASSWORD" > "$mysql_password_path"'
    echo '  cleanup_paths+=("$mysql_password_path")'
    echo '  extra_vars+=(-e "rivolution_remote_mysql_password_path=$mysql_password_path")'
    echo 'fi'
    echo '[ -n "$RIVOLUTION_REMOTE_NFS_HOST" ] && extra_vars+=(-e "rivolution_remote_nfs_host=$RIVOLUTION_REMOTE_NFS_HOST")'
    echo
    echo 'ansible-galaxy collection install community.general ansible.posix community.mysql'
    echo 'ansible-pull -U "$INSTALLER_REPO" -i "localhost," site.yml "${extra_vars[@]}"'
  } > "$out_file"
  chmod +x "$out_file"
  echo
  echo "Wrote $out_file -- paste its contents into your cloud provider's startup-script field, or run it as root on a fresh box (sudo bash $out_file)."
fi
