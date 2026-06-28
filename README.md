# Rivolution golden-image installer

An Ansible playbook that provisions a fresh Ubuntu 24.04 machine into a
working Rivolution radio automation install, from source, end to end:
build dependencies, desktop/xrdp/MATE, MariaDB, compile + install,
Apache/`rdxport.cgi` wiring, the `rivendell`/`pypad` system users and
`/var/snd`, a freshly generated database password, schema + seed data +
test tone, PulseAudio/ALSA handoff, and service enablement at boot.

It's a direct translation of a manual golden-image build log, refined
across several from-source installs to catch the gaps that the
project's own `.deb` packaging normally papers over (see the comments
in `roles/provision/templates/rivolution-first-run.sh.j2` for the details
on each one).

Tested target: Ubuntu 24.04, on a DigitalOcean Droplet, a UTM VM, and
physical hardware.

## Quick start: DigitalOcean Droplet

1. Copy the block below as-is -- by default this builds the public
   `anjeleno/rivolution` repo, so no edits are required to get started.
   Only edit the `RIVOLUTION_GIT_REPO` line if you want to point this
   at your own fork instead. See "Important" below for details.
2. DigitalOcean Droplet creation screen -> Additional Options -> Startup scripts (Free), paste it in.
3. Create the Droplet. It boots, installs Ansible, and provisions
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
  # newlines), which silently truncates a multi-line PEM key.
  deploy_key_path="$(mktemp)"
  chmod 600 "$deploy_key_path"
  printf '%s\n' "$RIVOLUTION_DEPLOY_KEY" > "$deploy_key_path"
  cleanup_paths+=("$deploy_key_path")
  extra_vars+=(-e "rivolution_deploy_key_path=$deploy_key_path")
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

## Important: this builds the public Rivolution repo by default

`group_vars/all.yml` defaults `rivolution_git_repo` to the public
`anjeleno/rivolution` repo on the `main` branch -- no access or key
needed to use the defaults as-is. Only override these if you want to
point the build at your own fork instead:

```yaml
rivolution_git_repo: git@github.com:youraccount/rivolution.git
rivolution_git_ref: your-branch-or-tag
```

If you point this at your own *private* fork, see "Private repo
access" below.

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

Only relevant if you've repointed `rivolution_git_repo` at your own
private fork -- the public default needs none of this.
`rivolution_deploy_key_path` (in `group_vars/all.yml`, or passed via
`-e`/`bootstrap.sh`) is a path to a private SSH key file with read
access to `rivolution_git_repo` -- a file path, not the key content
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
from scratch -- so it's guarded by a `/etc/rivolution-installer-provisioned`
marker file and only ever runs once per host. Delete that marker
yourself if you genuinely want to wipe and rebuild an existing
install's database.
