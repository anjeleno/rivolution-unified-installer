# Rivendell golden-image installer

An Ansible playbook that provisions a fresh Ubuntu 24.04 machine into a
working Rivendell radio automation install, from source, end to end:
build dependencies, desktop/xrdp/MATE, MariaDB, compile + install,
Apache/`rdxport.cgi` wiring, the `rivendell`/`pypad` system users and
`/var/snd`, a freshly generated database password, schema + seed data +
test tone, PulseAudio/ALSA handoff, and service enablement at boot.

It's a direct translation of a manual golden-image build log, refined
across several from-source installs to catch the gaps that the
project's own `.deb` packaging normally papers over (see the comments
in `roles/provision/templates/fix-rivendell-user.sh.j2` for the details
on each one).

Tested target: Ubuntu 24.04, on a DigitalOcean Droplet, a UTM VM, and
physical hardware.

## Quick start: DigitalOcean Droplet

1. **Before copying:** by default this builds a private fork
   (`anjeleno/rivendell`). If you don't have access to it, edit the
   `RIVENDELL_GIT_REPO` line below first -- e.g. set it to
   `https://github.com/ElvishArtisan/rivendell.git` (the public
   upstream) -- or the build will fail at the git clone step. See
   "Important" below for details.
2. Copy the block below.
3. DigitalOcean Droplet creation screen -> Additional Options -> Startup scripts (Free), paste it in.
4. Create the Droplet. It boots, installs Ansible, and provisions
   itself automatically -- no SSH in required to kick it off.

```bash
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
  # newlines), which silently truncates a multi-line PEM key.
  deploy_key_path="$(mktemp)"
  chmod 600 "$deploy_key_path"
  printf '%s\n' "$RIVENDELL_DEPLOY_KEY" > "$deploy_key_path"
  trap 'rm -f "$deploy_key_path"' EXIT
  extra_vars+=(-e "rivendell_deploy_key_path=$deploy_key_path")
fi

ansible-galaxy collection install community.general
ansible-pull -U "$INSTALLER_REPO" -i "localhost," site.yml "${extra_vars[@]}"
```

## Watch the build progress

SSH into your droplet and run the command:

```
sudo tail -f /var/log/cloud-init-output.log
```

This block is a copy of [`bootstrap.sh`](bootstrap.sh) in this repo --
if you change one, change the other so they don't drift apart. For a
UTM VM or physical box instead of a Droplet, download `bootstrap.sh`
and run it as root the same way (`sudo bash bootstrap.sh`) instead of
pasting it into a cloud provider's startup-script field.

## Important: this builds a specific git repo, which may be private

`group_vars/all.yml` defaults `rivendell_git_repo` to a private fork.
**If you don't have read access to that repo, the build step will fail
at the git clone.** Before running this against your own machine, set:

```yaml
rivendell_git_repo: https://github.com/ElvishArtisan/rivendell.git  # public upstream
rivendell_git_ref: v4                                                # or any tag/branch you want
```

or point it at your own fork. If your repo is private, see "Private
repo access" below.

## Usage

Pick one of these two methods -- they're alternatives, not sequential
steps.

### Method 1: control node pushes to a target over SSH

For a Droplet, UTM VM, or physical box that's already SSH-reachable as
root (or any sudo-capable user):

1. Add the target to `inventory/hosts.ini`.
2. `ansible-galaxy install -r requirements.yml`
3. `ansible-playbook site.yml`

### Method 2: paste into a Droplet's startup script (no SSH needed)

`bootstrap.sh` is meant to be pasted directly into DigitalOcean's
Droplet creation screen (Additional Options -> Startup scripts (Free)),
or run as-is on a freshly installed UTM VM / physical box. It installs
Ansible and uses `ansible-pull` to fetch this repo and run `site.yml`
against the local machine -- no inbound SSH or separate control node
required.

Edit the variables at the top of `bootstrap.sh` first (repo URL/ref
overrides, deploy key if needed), then paste the whole script in. You
do **not** need to touch `inventory/hosts.ini` for this method --
`bootstrap.sh` passes `-i "localhost,"` explicitly, which overrides
whatever's (or isn't) in that file. It exists purely for Method 1.

## Private repo access

`rivendell_deploy_key_path` (in `group_vars/all.yml`, or passed via
`-e`/`bootstrap.sh`) is a path to a private SSH key file with read
access to `rivendell_git_repo` -- a file path, not the key content
itself, since passing multi-line PEM content directly as an extra-var
value doesn't survive Ansible's CLI parsing. When set, the
`deploy_key` role copies it into the build user's `~/.ssh/`, scoped to
`github.com` only via `~/.ssh/config` so it's never used for anything
else. Leave it blank if your repo is public, or if the box already has
working git credentials some other way (e.g. you're running this from
your own machine with an agent already forwarding your normal key).

**Never commit a real key into this repo.** Pass it at runtime, ideally
via an Ansible Vault file (`ansible-playbook site.yml -e @secrets.yml
--ask-vault-pass`) rather than plain `-e` on the command line where
it'd show up in shell history.

## What's intentionally not automated

- Phase 0 (creating the Droplet / installing a base OS on a UTM VM or
  physical box) -- this playbook starts from "fresh Ubuntu 24.04,
  reachable as root," not before.
- Disk imaging/cloning a literal golden image (`dd`, streaming over
  SSH, importing into UTM) -- this playbook is the replacement for
  that workflow, not an addition to it. Run it fresh on each target
  instead of cloning a disk image.
- Per-station configuration inside Rivendell itself (Dropboxes, carts,
  schedule codes, RDAdmin host settings) -- this gets you to a running
  Rivendell with a test tone in the library, not a configured station.

## Re-running this playbook later

Everything except the database/test-tone step is safe to re-run (it'll
just confirm the existing state and move on). The database step is
deliberately **not** idempotent -- it drops and rebuilds the schema
from scratch -- so it's guarded by a `/etc/rivendell-installer-provisioned`
marker file and only ever runs once per host. Delete that marker
yourself if you genuinely want to wipe and rebuild an existing
install's database.
