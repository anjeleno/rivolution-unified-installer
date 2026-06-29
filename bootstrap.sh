#!/bin/bash
# Entry point for unattended use: paste this into a cloud provider's
# "User Data" / "Startup Script" field (e.g. DigitalOcean Droplet
# creation -> Additional Options -> Startup scripts (Free), or run
# it directly as root on a fresh Ubuntu 24.04 box (UTM VM, physical
# hardware install). It installs Ansible, then uses `ansible-pull` to
# fetch this repo and run site.yml against the local machine -- no
# inbound SSH access or separate control node required.
#
# Fill in the variables below before using this script. Everything
# else (build user, hostname, audio hardware, etc.) is configured in
# group_vars/all.yml in this repo -- override any of it here too via
# extra -e flags on the ansible-pull line at the bottom, if needed.
set -euo pipefail

# --- EDIT THESE -----------------------------------------------------
# This installer repo itself (safe to leave as-is once published).
INSTALLER_REPO="https://github.com/anjeleno/rivolution-unified-installer.git"

# Only needed if you want to override the defaults in group_vars/all.yml
# (e.g. to point at your own fork instead of the public rivolution repo).
RIVOLUTION_GIT_REPO=""
RIVOLUTION_GIT_REF=""

# This method has no real Ansible inventory (just -i "localhost,"), so
# rivolution_hostname's default ({{ inventory_hostname }}) would resolve
# to the literal string "localhost" and the base role would skip
# setting it. Defaults to "onair" -- override to name this box something
# else.
RIVOLUTION_HOSTNAME="onair"

# Private deploy key for RIVOLUTION_GIT_REPO, only needed if you've set
# that to a private repo above. Paste the entire key -- including the
# BEGIN/END lines -- between the quotes below. Leave empty if you're
# using the public default, or if this machine already has its own
# working git credentials configured.
RIVOLUTION_DEPLOY_KEY=""

# standalone | server | client -- see group_vars/all.yml for what each
# mode actually does. Leave as standalone unless you're deliberately
# building a multi-host deployment.
RIVOLUTION_INSTALL_MODE="standalone"

# Only used when RIVOLUTION_INSTALL_MODE=client -- a remote MySQL/
# MariaDB host and the audio store's NFS host to point this box at,
# instead of provisioning either locally.
RIVOLUTION_REMOTE_MYSQL_HOST=""
RIVOLUTION_REMOTE_MYSQL_USER="rduser"
RIVOLUTION_REMOTE_MYSQL_DATABASE="Rivendell"
RIVOLUTION_REMOTE_MYSQL_PASSWORD=""
RIVOLUTION_REMOTE_NFS_HOST=""

# Set to "true" to enable the advanced broadcast-tool bundle (Icecast/
# Liquidsoap/VLC/JACK patches/Stereo Tool + a seed database). Requires
# RIVOLUTION_HOSTNAME above to be exactly "onair" -- the seed data is
# keyed to that host name -- and is destructive on first run (replaces
# the existing database, after an automatic backup). See this repo's
# README "Advanced mode" section before enabling. Leave blank to skip.
RIVOLUTION_ADVANCED_BROADCAST_CONFIG=""

# Set to "true" to enable the security-hardening bundle (ufw + SSH
# key-only login, only if a working authorized_keys already exists).
# Independent of advanced mode above. Leave blank to skip.
RIVOLUTION_HARDEN_SECURITY=""
RIVOLUTION_HARDEN_EXTERNAL_IP=""
RIVOLUTION_HARDEN_LAN_SUBNET=""
# ----------------------------------------------------------------------

apt-get update
apt-get install -y --no-install-recommends git ansible

extra_vars=()

# Temp files created below are tracked here and cleaned up by one
# combined trap -- calling `trap ... EXIT` more than once replaces the
# previous handler rather than adding to it, so each secret below
# appends to this array instead of setting its own trap.
cleanup_paths=()
cleanup() { rm -f "${cleanup_paths[@]}"; }
trap cleanup EXIT

[ -n "$RIVOLUTION_GIT_REPO" ] && extra_vars+=(-e "rivolution_git_repo=$RIVOLUTION_GIT_REPO")
[ -n "$RIVOLUTION_GIT_REF" ] && extra_vars+=(-e "rivolution_git_ref=$RIVOLUTION_GIT_REF")
[ -n "$RIVOLUTION_HOSTNAME" ] && extra_vars+=(-e "rivolution_hostname=$RIVOLUTION_HOSTNAME")
[ -n "$RIVOLUTION_INSTALL_MODE" ] && extra_vars+=(-e "rivolution_install_mode=$RIVOLUTION_INSTALL_MODE")

if [ -n "$RIVOLUTION_DEPLOY_KEY" ]; then
  # Written to a file rather than passed via -e: Ansible's plain
  # key=value extra-vars parsing splits on whitespace (including
  # newlines) to support multiple pairs in one string, which silently
  # truncates a multi-line PEM key to its first line. A file path has
  # no such problem, and never echoes the key into any log.
  deploy_key_path="$(mktemp)"
  chmod 600 "$deploy_key_path"
  printf '%s\n' "$RIVOLUTION_DEPLOY_KEY" > "$deploy_key_path"
  cleanup_paths+=("$deploy_key_path")
  extra_vars+=(-e "rivolution_deploy_key_path=$deploy_key_path")
fi

[ -n "$RIVOLUTION_REMOTE_MYSQL_HOST" ] && extra_vars+=(-e "rivolution_remote_mysql_host=$RIVOLUTION_REMOTE_MYSQL_HOST")
[ -n "$RIVOLUTION_REMOTE_MYSQL_USER" ] && extra_vars+=(-e "rivolution_remote_mysql_user=$RIVOLUTION_REMOTE_MYSQL_USER")
[ -n "$RIVOLUTION_REMOTE_MYSQL_DATABASE" ] && extra_vars+=(-e "rivolution_remote_mysql_database=$RIVOLUTION_REMOTE_MYSQL_DATABASE")
if [ -n "$RIVOLUTION_REMOTE_MYSQL_PASSWORD" ]; then
  # Same file-path treatment as the deploy key, and for the same
  # reason: passing a real secret as -e content directly would put it
  # in `ps aux` output and potentially in Ansible's own verbose
  # logging. The multi-line-PEM parsing bug doesn't apply to a plain
  # password, but the exposure risk does.
  mysql_password_path="$(mktemp)"
  chmod 600 "$mysql_password_path"
  printf '%s\n' "$RIVOLUTION_REMOTE_MYSQL_PASSWORD" > "$mysql_password_path"
  cleanup_paths+=("$mysql_password_path")
  extra_vars+=(-e "rivolution_remote_mysql_password_path=$mysql_password_path")
fi
[ -n "$RIVOLUTION_REMOTE_NFS_HOST" ] && extra_vars+=(-e "rivolution_remote_nfs_host=$RIVOLUTION_REMOTE_NFS_HOST")
[ -n "$RIVOLUTION_ADVANCED_BROADCAST_CONFIG" ] && extra_vars+=(-e "rivolution_advanced_broadcast_config=$RIVOLUTION_ADVANCED_BROADCAST_CONFIG")
[ -n "$RIVOLUTION_HARDEN_SECURITY" ] && extra_vars+=(-e "rivolution_harden_security=$RIVOLUTION_HARDEN_SECURITY")
[ -n "$RIVOLUTION_HARDEN_EXTERNAL_IP" ] && extra_vars+=(-e "rivolution_harden_external_ip=$RIVOLUTION_HARDEN_EXTERNAL_IP")
[ -n "$RIVOLUTION_HARDEN_LAN_SUBNET" ] && extra_vars+=(-e "rivolution_harden_lan_subnet=$RIVOLUTION_HARDEN_LAN_SUBNET")

ansible-galaxy collection install community.general ansible.posix community.mysql
ansible-pull -U "$INSTALLER_REPO" -i "localhost," site.yml "${extra_vars[@]}"
