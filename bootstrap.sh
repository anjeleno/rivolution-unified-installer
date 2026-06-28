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
INSTALLER_REPO="https://github.com/anjeleno/rivendell-golden-ansible.git"

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

ansible-galaxy collection install community.general
ansible-pull -U "$INSTALLER_REPO" -i "localhost," site.yml "${extra_vars[@]}"
