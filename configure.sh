#!/bin/bash
# Interactive front end for this installer. Asks a handful of
# questions once, then either runs ansible-playbook over SSH against a
# separate host you give it (Method 1: ssh), runs it directly against
# the box you're already logged into, no SSH (Method 2: local -- if
# this process isn't already root, it re-execs itself under sudo,
# which prompts for your password right there), or writes out a fully
# filled-in bootstrap.sh for you to paste into a cloud provider's
# startup-script field before a droplet even exists (Method 3:
# bootstrap). Either way, the target never has to answer a prompt
# itself -- by the time anything runs unattended, every answer is
# already baked in.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# Set by the sudo re-exec below (after Method 2 is chosen by a
# non-root invocation) so the re-exec'd, now-root process doesn't ask
# the same question again.
preset_method=""
# Skips the "Install Rivolution by..." prompt below -- e.g. for a
# non-interactive local source-method install:
#   ./configure.sh --method=local --install-method=source
preset_install_method=""
for arg in "$@"; do
  case "$arg" in
    --method=*) preset_method="${arg#--method=}" ;;
    --install-method=*)
      preset_install_method="${arg#--install-method=}"
      if [ "$preset_install_method" != "deb" ] && [ "$preset_install_method" != "source" ]; then
        echo "Error: --install-method must be 'deb' or 'source', got '$preset_install_method'" >&2
        exit 1
      fi
      ;;
  esac
done

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

choose() {
  # choose "Prompt text" "default option" "opt1" "opt2" ... -> echoes
  # the chosen option string. Prints a numbered menu and only accepts
  # a number from that menu -- never the option text itself.
  local prompt="$1" default="$2"; shift 2
  local opts=("$@") i default_index=1 reply
  for i in "${!opts[@]}"; do
    [ "${opts[$i]}" = "$default" ] && default_index=$((i + 1))
  done
  echo "$prompt" >&2
  for i in "${!opts[@]}"; do
    echo "  $((i + 1)). ${opts[$i]}" >&2
  done
  read -r -p "Choice [$default_index]: " reply
  reply="${reply:-$default_index}"
  if ! [[ "$reply" =~ ^[1-9][0-9]*$ ]] || [ "$reply" -gt "${#opts[@]}" ]; then
    echo "Unrecognized choice '$reply' -- enter a number from 1 to ${#opts[@]}." >&2
    exit 1
  fi
  echo "${opts[$((reply - 1))]}"
}

echo "=== Rivolution unified installer setup ==="
echo

if [ -n "$preset_method" ]; then
  method="$preset_method"
else
  echo "ssh:       push from a separate control machine, over SSH, to a"
  echo "           box that's already running and reachable."
  echo "local:     you're already logged into the target box right now --"
  echo "           run the playbook directly against this machine, no SSH."
  echo "bootstrap: generate a bootstrap.sh to paste into a cloud provider's"
  echo "           startup-script field before the box even exists."
  echo
  method="$(choose "How do you want to provision the target?" "ssh" \
    "ssh" \
    "local" \
    "bootstrap")"
fi

# site.yml's become: true needs root for local mode to actually take
# effect. Rather than just erroring and telling the user to re-run
# with sudo (which means re-answering every question from scratch),
# re-exec this same script under sudo right here -- sudo prompts for
# the password itself, interactively, exactly like running any other
# command with sudo. --method=local carries the already-made choice
# through the re-exec so the now-root process doesn't ask again.
if [ "$method" = "local" ] && [ "$EUID" -ne 0 ]; then
  echo
  echo "Local mode needs root -- re-running this script with sudo (you may be prompted for your password)."
  reexec_args=(--method=local)
  [ -n "$preset_install_method" ] && reexec_args+=(--install-method="$preset_install_method")
  exec sudo "$SCRIPT_PATH" "${reexec_args[@]}"
fi

# ssh and local both run ansible-galaxy/ansible-playbook directly
# (bootstrap mode doesn't reach this script at all; its generated
# script apt-installs ansible itself). A common trap: Ansible
# installed via 'pip install --user ansible' lands in ~/.local/bin,
# which is on a normal user's PATH but not root's -- sudo resets PATH
# (secure_path) and won't see it, even though the same command works
# fine without sudo as the same user.
if [ "$method" != "bootstrap" ]; then
  missing=()
  command -v ansible-galaxy >/dev/null 2>&1 || missing+=(ansible-galaxy)
  command -v ansible-playbook >/dev/null 2>&1 || missing+=(ansible-playbook)
  if [ "${#missing[@]}" -gt 0 ]; then
    if [ "$method" = "local" ]; then
      # Safe to auto-install here, unprompted, the same way
      # bootstrap.sh already does unconditionally: local mode only
      # ever runs as root (guaranteed by the re-exec above) against
      # the target box itself, which this installer already requires
      # to be Ubuntu/Debian -- apt is guaranteed to exist. ssh mode
      # runs on whatever the control machine happens to be (could be
      # macOS, Fedora, anything), so it stays manual below instead of
      # assuming apt.
      echo "Ansible not found -- installing it now (apt-get install -y ansible)..."
      apt-get update
      apt-get install -y --no-install-recommends ansible
    else
      echo "Error: missing from PATH: ${missing[*]}" >&2
      echo "Install Ansible on this control machine first:" >&2
      echo "  sudo apt update && sudo apt install -y ansible" >&2
      exit 1
    fi
  fi
fi

if [ -n "$preset_install_method" ]; then
  install_method="$preset_install_method"
else
  install_method="$(choose "Install Rivolution by..." "deb" \
    "deb" \
    "source")"
fi

release_tag=""
if [ "$install_method" = "deb" ]; then
  release_tag="$(ask "Release tag to install (blank = latest)")"
fi

install_mode="$(choose "Install mode" "standalone" \
  "standalone" \
  "server" \
  "client")"

build_user="$(ask "Install/build user" "rd")"
read -r -s -p "Password for $build_user (blank to leave unset -- login only via SSH key or sudo): " build_user_password; echo

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
security_hardening="no"
harden_external_ip="" harden_lan_subnet=""
if confirm "Enable security hardening (firewall + SSH key-only login)?"; then
  security_hardening="yes"
  harden_external_ip="$(ask "External IP to allow through the firewall (blank to skip)")"
  harden_lan_subnet="$(ask "LAN subnet to allow, e.g. 192.168.1.0/24 (blank to skip)")"
fi

echo
tailscale_enabled="no"
tailscale_authkey=""
if confirm "Enable Tailscale (installs + enables tailscaled; doesn't auto-connect without a key)?"; then
  tailscale_enabled="yes"
  read -r -s -p "Tailscale auth key (blank to just install + enable, activate later): " tailscale_authkey; echo
fi

hostname_default="onair"
hostname="$(ask "Rivolution hostname" "$hostname_default")"

extra_vars=(-e "rivolution_install_method=$install_method" -e "rivolution_install_mode=$install_mode" -e "rivolution_user=$build_user" -e "rivolution_hostname=$hostname")
[ -n "$release_tag" ] && extra_vars+=(-e "rivolution_release_tag=$release_tag")
[ "$security_hardening" = "yes" ] && extra_vars+=(-e "rivolution_harden_security=true")
[ -n "$harden_external_ip" ] && extra_vars+=(-e "rivolution_harden_external_ip=$harden_external_ip")
[ -n "$harden_lan_subnet" ] && extra_vars+=(-e "rivolution_harden_lan_subnet=$harden_lan_subnet")
[ "$tailscale_enabled" = "yes" ] && extra_vars+=(-e "rivolution_tailscale_enabled=true")
[ -n "$remote_mysql_host" ] && extra_vars+=(-e "rivolution_remote_mysql_host=$remote_mysql_host")
[ -n "$remote_mysql_user" ] && extra_vars+=(-e "rivolution_remote_mysql_user=$remote_mysql_user")
[ -n "$remote_mysql_database" ] && extra_vars+=(-e "rivolution_remote_mysql_database=$remote_mysql_database")
[ -n "$remote_nfs_host" ] && extra_vars+=(-e "rivolution_remote_nfs_host=$remote_nfs_host")


remote_mysql_password_path="" tailscale_authkey_path="" build_user_password_path=""
cleanup() {
  [ -n "$remote_mysql_password_path" ] && rm -f "$remote_mysql_password_path"
  [ -n "$tailscale_authkey_path" ] && rm -f "$tailscale_authkey_path"
  [ -n "$build_user_password_path" ] && rm -f "$build_user_password_path"
  return 0
}
trap cleanup EXIT
if [ -n "$remote_mysql_password" ]; then
  remote_mysql_password_path="$(mktemp)"
  chmod 600 "$remote_mysql_password_path"
  printf '%s\n' "$remote_mysql_password" > "$remote_mysql_password_path"
  extra_vars+=(-e "rivolution_remote_mysql_password_path=$remote_mysql_password_path")
fi
if [ -n "$tailscale_authkey" ]; then
  tailscale_authkey_path="$(mktemp)"
  chmod 600 "$tailscale_authkey_path"
  printf '%s\n' "$tailscale_authkey" > "$tailscale_authkey_path"
  extra_vars+=(-e "rivolution_tailscale_authkey_path=$tailscale_authkey_path")
fi
if [ -n "$build_user_password" ]; then
  build_user_password_path="$(mktemp)"
  chmod 600 "$build_user_password_path"
  printf '%s\n' "$build_user_password" > "$build_user_password_path"
  extra_vars+=(-e "rivolution_user_password_path=$build_user_password_path")
fi

if [ "$method" = "ssh" ]; then
  echo
  target_host="$(ask "Target host (IP or hostname), already SSH-reachable")"
  target_user="$(ask "SSH user on the target (root, or any sudo-capable account)" "root")"
  echo
  echo "Running: ansible-playbook -i \"$target_host,\" -u \"$target_user\" site.yml ..."
  cd "$SCRIPT_DIR"
  ansible-galaxy collection install -r requirements.yml
  ansible-playbook -i "$target_host," -u "$target_user" site.yml "${extra_vars[@]}"
elif [ "$method" = "local" ]; then
  # No SSH at all -- ansible_connection=local runs every task as a
  # direct subprocess on this machine instead of opening a loopback SSH
  # session to itself (which would otherwise need this account's own
  # key already trusted in its own authorized_keys). Root/sudo already
  # checked immediately after method was chosen, above.
  echo
  echo "Running: ansible-playbook -i \"localhost,\" -c local site.yml ..."
  cd "$SCRIPT_DIR"
  ansible-galaxy collection install -r requirements.yml
  ansible-playbook -i "localhost," -c local site.yml "${extra_vars[@]}"
else
  out_file="$SCRIPT_DIR/bootstrap-generated.sh"
  {
    echo '#!/bin/bash'
    echo "# Generated by configure.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ) -- paste this whole block into your"
    echo "# cloud provider's startup-script field, or run it as root on a fresh box."
    echo 'set -euo pipefail'
    echo
    echo 'INSTALLER_REPO="https://github.com/anjeleno/rivolution-unified-installer.git"'
    echo "RIVOLUTION_HOSTNAME=\"$hostname\""
    echo "RIVOLUTION_INSTALL_METHOD=\"$install_method\""
    echo "RIVOLUTION_RELEASE_TAG=\"$release_tag\""
    echo "RIVOLUTION_INSTALL_MODE=\"$install_mode\""
    echo "RIVOLUTION_REMOTE_MYSQL_HOST=\"$remote_mysql_host\""
    echo "RIVOLUTION_REMOTE_MYSQL_USER=\"$remote_mysql_user\""
    echo "RIVOLUTION_REMOTE_MYSQL_DATABASE=\"$remote_mysql_database\""
    echo "RIVOLUTION_REMOTE_MYSQL_PASSWORD=\"$remote_mysql_password\""
    echo "RIVOLUTION_REMOTE_NFS_HOST=\"$remote_nfs_host\""
    echo "RIVOLUTION_TAILSCALE_AUTHKEY=\"$tailscale_authkey\""
    echo "RIVOLUTION_USER_PASSWORD=\"$build_user_password\""
    echo
    echo 'apt-get update'
    echo 'apt-get install -y --no-install-recommends git ansible'
    echo
    echo 'extra_vars=()'
    echo 'cleanup_paths=()'
    echo 'cleanup() { rm -f "${cleanup_paths[@]}"; }'
    echo 'trap cleanup EXIT'
    echo '[ -n "$RIVOLUTION_HOSTNAME" ] && extra_vars+=(-e "rivolution_hostname=$RIVOLUTION_HOSTNAME")'
    echo '[ -n "$RIVOLUTION_INSTALL_METHOD" ] && extra_vars+=(-e "rivolution_install_method=$RIVOLUTION_INSTALL_METHOD")'
    echo '[ -n "$RIVOLUTION_RELEASE_TAG" ] && extra_vars+=(-e "rivolution_release_tag=$RIVOLUTION_RELEASE_TAG")'
    echo '[ -n "$RIVOLUTION_INSTALL_MODE" ] && extra_vars+=(-e "rivolution_install_mode=$RIVOLUTION_INSTALL_MODE")'
    echo "extra_vars+=(-e \"rivolution_user=$build_user\")"
    [ "$security_hardening" = "yes" ] && echo 'extra_vars+=(-e "rivolution_harden_security=true")'
    [ -n "$harden_external_ip" ] && echo "extra_vars+=(-e \"rivolution_harden_external_ip=$harden_external_ip\")"
    [ -n "$harden_lan_subnet" ] && echo "extra_vars+=(-e \"rivolution_harden_lan_subnet=$harden_lan_subnet\")"
    [ "$tailscale_enabled" = "yes" ] && echo 'extra_vars+=(-e "rivolution_tailscale_enabled=true")'
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
    echo 'if [ -n "$RIVOLUTION_TAILSCALE_AUTHKEY" ]; then'
    echo '  tailscale_authkey_path="$(mktemp)"'
    echo '  chmod 600 "$tailscale_authkey_path"'
    echo '  printf '"'"'%s\n'"'"' "$RIVOLUTION_TAILSCALE_AUTHKEY" > "$tailscale_authkey_path"'
    echo '  cleanup_paths+=("$tailscale_authkey_path")'
    echo '  extra_vars+=(-e "rivolution_tailscale_authkey_path=$tailscale_authkey_path")'
    echo 'fi'
    echo 'if [ -n "$RIVOLUTION_USER_PASSWORD" ]; then'
    echo '  user_password_path="$(mktemp)"'
    echo '  chmod 600 "$user_password_path"'
    echo '  printf '"'"'%s\n'"'"' "$RIVOLUTION_USER_PASSWORD" > "$user_password_path"'
    echo '  cleanup_paths+=("$user_password_path")'
    echo '  extra_vars+=(-e "rivolution_user_password_path=$user_password_path")'
    echo 'fi'
    echo
    echo 'ansible-galaxy collection install community.general ansible.posix community.mysql'
    echo 'ansible-pull -U "$INSTALLER_REPO" -i "localhost," site.yml "${extra_vars[@]}"'
  } > "$out_file"
  chmod +x "$out_file"
  echo
  echo "Wrote $out_file -- paste its contents into your cloud provider's startup-script field, or run it as root on a fresh box (sudo bash $out_file)."
fi
