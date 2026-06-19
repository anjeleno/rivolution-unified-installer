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

# Only needed if you want to override the defaults in group_vars/all.yml.
RIVENDELL_GIT_REPO=""
RIVENDELL_GIT_REF=""

# This method has no real Ansible inventory (just -i "localhost,"), so
# rivendell_hostname's default ({{ inventory_hostname }}) would resolve
# to the literal string "localhost" and the base role would skip
# setting it. Set a real hostname here if you want one applied.
RIVENDELL_HOSTNAME=""

# Private deploy key for RIVENDELL_GIT_REPO, if it's a private repo.
# Paste the entire key -- including the BEGIN/END lines -- between the
# quotes below. Leave empty if the repo is public, or if this machine
# already has its own working git credentials configured.
RIVENDELL_DEPLOY_KEY=""
# ----------------------------------------------------------------------

apt-get update
apt-get install -y --no-install-recommends git ansible

extra_vars=()
[ -n "$RIVENDELL_GIT_REPO" ] && extra_vars+=(-e "rivendell_git_repo=$RIVENDELL_GIT_REPO")
[ -n "$RIVENDELL_GIT_REF" ] && extra_vars+=(-e "rivendell_git_ref=$RIVENDELL_GIT_REF")
[ -n "$RIVENDELL_HOSTNAME" ] && extra_vars+=(-e "rivendell_hostname=$RIVENDELL_HOSTNAME")
if [ -n "$RIVENDELL_DEPLOY_KEY" ]; then
  # Written to a file rather than passed via -e: Ansible's plain
  # key=value extra-vars parsing splits on whitespace (including
  # newlines) to support multiple pairs in one string, which silently
  # truncates a multi-line PEM key to its first line. A file path has
  # no such problem, and never echoes the key into any log.
  deploy_key_path="$(mktemp)"
  chmod 600 "$deploy_key_path"
  printf '%s\n' "$RIVENDELL_DEPLOY_KEY" > "$deploy_key_path"
  trap 'rm -f "$deploy_key_path"' EXIT
  extra_vars+=(-e "rivendell_deploy_key_path=$deploy_key_path")
fi

ansible-galaxy collection install community.general
ansible-pull -U "$INSTALLER_REPO" -i "localhost," site.yml "${extra_vars[@]}"
