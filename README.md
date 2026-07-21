# Rivolution unified installer

An Ansible playbook that provisions a fresh Ubuntu 24.04/26.04 machine
(x64 or arm64) into a working Rivolution radio automation install, end
to end: OS/desktop/xrdp setup, audio-hardware detection, installing
Rivolution itself, and the network topology (standalone/server/client).

By default this installs the project's own released `.deb` package --
downloaded straight from GitHub Releases, the same artifact everyone
else installs. From there, `debian/postinst` (maintained in
[the main repo](https://github.com/anjeleno/rivolution)) does the real
provisioning: system users, `/var/snd`, the database, every
broadcast-stack systemd unit, sudoers, udev, `.asoundrc`, Apache
wiring, the lot. This installer's job is getting a `.deb` onto the box
and telling `apt` to install it, plus the handful of things that
genuinely can't be a package's job (OS/desktop setup, audio-hardware
detection, network topology, Tailscale). See
[`docs/specs/0004-deb-based-provisioning.md`](docs/specs/0004-deb-based-provisioning.md)
for the full design and reasoning.

An opt-in `rivolution_install_method: source` builds a local `.deb`
from a git checkout instead of downloading one -- useful for a private
fork, an unreleased branch, or a target with no published release asset
yet (Debian Trixie, currently -- see
["Install method"](#install-method-deb-default-or-source) below).
Either way, `postinst` runs the exact same way from an identical `apt
install` step, so there's no separate, easier-to-forget provisioning
path for the source option to fall behind on.

Tested target: Ubuntu 24.04/26.04 (x64 and arm64), on a DigitalOcean
Droplet, a UTM VM, and physical hardware.

## Quick start: DigitalOcean Droplet

1. Copy the block below as-is -- by default this installs the latest
   published release of the public `anjeleno/rivolution` repo, so no
   edits are required to get started.
2. DigitalOcean Droplet creation screen -> Additional Options -> Startup scripts (Free), paste it in.
3. Create the Droplet. It boots, installs Ansible, and provisions
   itself automatically -- no SSH in required to kick it off.

```bash
#!/bin/bash
# Entry point for unattended use: paste this into a cloud provider's
# "User Data" / "Startup Script" field (e.g. DigitalOcean Droplet
# creation -> Additional Options -> Startup scripts (Free), or run
# it directly as root on a fresh Ubuntu 24.04/26.04 box (UTM VM,
# physical hardware install). It installs Ansible, then uses
# `ansible-pull` to fetch this repo and run site.yml against the local
# machine -- no inbound SSH access or separate control node required.
#
# Fill in the variables below before using this script. Everything
# else (install user, hostname, audio hardware, etc.) is configured in
# group_vars/all.yml in this repo -- override any of it here too via
# extra -e flags on the ansible-pull line at the bottom, if needed.
set -euo pipefail

# --- EDIT THESE -----------------------------------------------------
# This installer repo itself (safe to leave as-is once published).
INSTALLER_REPO="https://github.com/anjeleno/rivolution-unified-installer.git"

# deb (default): download and apt-install the matching release .deb.
# source: clone RIVOLUTION_GIT_REPO/_REF below and build a local .deb
#   from it instead.
RIVOLUTION_INSTALL_METHOD=""

# Only consulted when RIVOLUTION_INSTALL_METHOD=deb. Blank (default)
# installs the latest published release; set to an exact tag (e.g.
# "v6.0.0-rc1-2") to pin one instead.
RIVOLUTION_RELEASE_TAG=""

# Only consulted when RIVOLUTION_INSTALL_METHOD=source. Override the
# defaults in group_vars/all.yml (e.g. to point at your own fork
# instead of the public rivolution repo).
RIVOLUTION_GIT_REPO=""
RIVOLUTION_GIT_REF=""

# This method has no real Ansible inventory (just -i "localhost,"), so
# rivolution_hostname's default ({{ inventory_hostname }}) would resolve
# to the literal string "localhost" and the base role would skip
# setting it. Defaults to "onair" -- override to name this box something
# else.
RIVOLUTION_HOSTNAME="onair"

# Private deploy key for RIVOLUTION_GIT_REPO, only relevant under
# RIVOLUTION_INSTALL_METHOD=source pointed at a private fork. Paste the
# entire key -- including the BEGIN/END lines -- between the quotes
# below. Leave empty if you're using the public default, or if this
# machine already has its own working git credentials configured.
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

# Set to "true" to enable the security-hardening bundle (ufw + SSH
# key-only login, only if a working authorized_keys already exists).
# Leave blank to skip.
RIVOLUTION_HARDEN_SECURITY=""
RIVOLUTION_HARDEN_EXTERNAL_IP=""
RIVOLUTION_HARDEN_LAN_SUBNET=""

# Set to "true" to install and enable (but not start) tailscaled.
# Leave RIVOLUTION_TAILSCALE_AUTHKEY blank to activate it yourself
# later; set it to a real auth key to activate immediately.
RIVOLUTION_TAILSCALE_ENABLED=""
RIVOLUTION_TAILSCALE_AUTHKEY=""
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

[ -n "$RIVOLUTION_INSTALL_METHOD" ] && extra_vars+=(-e "rivolution_install_method=$RIVOLUTION_INSTALL_METHOD")
[ -n "$RIVOLUTION_RELEASE_TAG" ] && extra_vars+=(-e "rivolution_release_tag=$RIVOLUTION_RELEASE_TAG")
[ -n "$RIVOLUTION_GIT_REPO" ] && extra_vars+=(-e "rivolution_git_repo=$RIVOLUTION_GIT_REPO")
[ -n "$RIVOLUTION_GIT_REF" ] && extra_vars+=(-e "rivolution_git_ref=$RIVOLUTION_GIT_REF")
[ -n "$RIVOLUTION_HOSTNAME" ] && extra_vars+=(-e "rivolution_hostname=$RIVOLUTION_HOSTNAME")
[ -n "$RIVOLUTION_INSTALL_MODE" ] && extra_vars+=(-e "rivolution_install_mode=$RIVOLUTION_INSTALL_MODE")

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

[ -n "$RIVOLUTION_REMOTE_MYSQL_HOST" ] && extra_vars+=(-e "rivolution_remote_mysql_host=$RIVOLUTION_REMOTE_MYSQL_HOST")
[ -n "$RIVOLUTION_REMOTE_MYSQL_USER" ] && extra_vars+=(-e "rivolution_remote_mysql_user=$RIVOLUTION_REMOTE_MYSQL_USER")
[ -n "$RIVOLUTION_REMOTE_MYSQL_DATABASE" ] && extra_vars+=(-e "rivolution_remote_mysql_database=$RIVOLUTION_REMOTE_MYSQL_DATABASE")
if [ -n "$RIVOLUTION_REMOTE_MYSQL_PASSWORD" ]; then
  mysql_password_path="$(mktemp)"
  chmod 600 "$mysql_password_path"
  printf '%s\n' "$RIVOLUTION_REMOTE_MYSQL_PASSWORD" > "$mysql_password_path"
  cleanup_paths+=("$mysql_password_path")
  extra_vars+=(-e "rivolution_remote_mysql_password_path=$mysql_password_path")
fi
[ -n "$RIVOLUTION_REMOTE_NFS_HOST" ] && extra_vars+=(-e "rivolution_remote_nfs_host=$RIVOLUTION_REMOTE_NFS_HOST")
[ -n "$RIVOLUTION_HARDEN_SECURITY" ] && extra_vars+=(-e "rivolution_harden_security=$RIVOLUTION_HARDEN_SECURITY")
[ -n "$RIVOLUTION_HARDEN_EXTERNAL_IP" ] && extra_vars+=(-e "rivolution_harden_external_ip=$RIVOLUTION_HARDEN_EXTERNAL_IP")
[ -n "$RIVOLUTION_HARDEN_LAN_SUBNET" ] && extra_vars+=(-e "rivolution_harden_lan_subnet=$RIVOLUTION_HARDEN_LAN_SUBNET")
[ -n "$RIVOLUTION_TAILSCALE_ENABLED" ] && extra_vars+=(-e "rivolution_tailscale_enabled=$RIVOLUTION_TAILSCALE_ENABLED")
if [ -n "$RIVOLUTION_TAILSCALE_AUTHKEY" ]; then
  tailscale_authkey_path="$(mktemp)"
  chmod 600 "$tailscale_authkey_path"
  printf '%s\n' "$RIVOLUTION_TAILSCALE_AUTHKEY" > "$tailscale_authkey_path"
  cleanup_paths+=("$tailscale_authkey_path")
  extra_vars+=(-e "rivolution_tailscale_authkey_path=$tailscale_authkey_path")
fi

ansible-galaxy collection install community.general ansible.posix community.mysql
ansible-pull -U "$INSTALLER_REPO" -i "localhost," site.yml "${extra_vars[@]}"
```

## Watch the build progress

SSH into your droplet and run the command:

```
sudo tail -f /var/log/cloud-init-output.log
```

This block is a copy of [`bootstrap.sh`](bootstrap.sh) in this repo --
if you change one, change the other so they don't drift apart. For a
UTM VM or physical box instead of a Droplet, download
[`bootstrap.sh`](bootstrap.sh) and run it as root the same way
(`sudo bash bootstrap.sh`) instead of pasting it into a cloud
provider's startup-script field.

## Install method: `deb` (default) or `source`

`rivolution_install_method` picks where Rivolution itself comes from:

- **`deb`** (default) -- downloads the matching release asset from
  [GitHub Releases](https://github.com/anjeleno/rivolution/releases)
  for this host's architecture (and, for amd64, its Ubuntu version --
  26.04 gets the primary build, 24.04 gets the `-noble` build) and
  installs it. `rivolution_release_tag` (blank = latest published
  release) can pin an exact version instead.
- **`source`** -- clones `rivolution_git_repo`/`rivolution_git_ref`
  (defaults to the public repo's `main` branch) and builds a real local
  `.deb` from it (`dpkg-buildpackage`, via the main repo's own
  `scripts/rebuild-deb.sh --no-bump`), then installs *that* through the
  identical step the `deb` method uses. Not a separate provisioning
  path -- `debian/postinst` runs exactly the same way either way. Use
  this for a private fork, an unreleased branch, or a target with no
  published release asset -- currently, that means Debian Trixie: no
  Debian-built `.deb` exists yet (tracked in
  [the main repo's `BACKLOG.md`](https://github.com/anjeleno/rivolution/blob/main/BACKLOG.md)),
  so `source` is the only way to install there today.

```yaml
rivolution_install_method: source
rivolution_git_repo: git@github.com:youraccount/rivolution.git
rivolution_git_ref: your-branch-or-tag
```

If you point `source` at your own *private* fork, see
["Private repo access"](#private-repo-access) below.

## Usage

Pick one of these three methods -- they're alternatives, not
sequential steps. Either way,
[`./configure.sh`](#configuresh-the-interactive-front-end) asks the
per-install questions once and can drive any of them for you, or you
can do everything by hand as described in each method.

### configure.sh: the interactive front end

[`./configure.sh`](configure.sh) asks for install method, install mode,
install user, Tailscale, and security hardening once, then either runs
`ansible-playbook` directly against a separate host you give it over
SSH ([Method 1](#method-1-control-node-pushes-to-a-target-over-ssh)),
runs it directly against the box you're already logged into, no SSH at
all ([Method 2](#method-2-run-directly-on-the-target-no-ssh) -- this is
what you want if you've SSH'd into the target yourself and are running
`configure.sh` on it directly), or writes a fully filled-in
`bootstrap-generated.sh` for you to paste into a cloud provider's
startup-script field for a box that doesn't exist yet
([Method 3](#method-3-paste-into-a-droplets-startup-script-no-ssh-needed)).
The target box itself never has to answer a prompt -- by the time
anything runs unattended, every answer is already baked in.

If you choose Method 2 (local) and `./configure.sh` isn't already
running as root, it re-execs itself under `sudo` right at that point
-- you'll be prompted for your password there, same as running any
other command with `sudo`, without having to remember to start the
script with `sudo` yourself or re-answer every question if you forget.
If Ansible itself isn't installed yet, Method 2 also installs it
automatically once it's root (`apt-get install -y ansible`) -- safe to
do unprompted there, since the target is already guaranteed to be
Ubuntu/Debian. Method 1, which runs on whatever your separate control
machine happens to be, does neither of these -- see its prerequisite
note below.

### Method 1: control node pushes to a target over SSH

Requires Ansible already installed on this machine
(`sudo apt update && sudo apt install -y ansible`). For a Droplet, UTM
VM, or physical box that's already SSH-reachable as root (or any
sudo-capable user), run this **from a separate machine**:

1. Add the target to `inventory/hosts.ini`.
2. Install the required collections:

```bash
ansible-galaxy install -r requirements.yml
```

3. Run the playbook:

```bash
ansible-playbook site.yml
```

### Method 2: run directly on the target, no SSH

This is the manual, by-hand equivalent of choosing "local" in
[`./configure.sh`](configure.sh) -- not deprecated by it, just the
non-interactive version. Requires Ansible already installed on this
box (`sudo apt update && sudo apt install -y ansible`) -- installed
system-wide via `apt`, not via `pip install --user`, since `sudo`
resets `PATH` and won't see a user-local install. If you're already
logged into the box (a fresh Droplet, UTM VM, or physical box you've
SSH'd or console'd into), run this **on that same box**, as root or a
user with passwordless `sudo` (prefix both commands below with `sudo`
if you're not already root -- [`site.yml`](site.yml) uses
`become: true` throughout, which needs one or the other to actually
take effect):

1. Install the required collections:

```bash
ansible-galaxy install -r requirements.yml
```

2. Run the playbook directly against this machine:

```bash
ansible-playbook -i "localhost," -c local site.yml
```

`-c local` runs every task as a direct subprocess instead of opening a
loopback SSH connection to itself -- no need for this account's own
SSH key to already be trusted in its own `authorized_keys`.

### Method 3: paste into a Droplet's startup script (no SSH needed)

[`bootstrap.sh`](bootstrap.sh) is meant to be pasted directly into
DigitalOcean's Droplet creation screen (Additional Options -> Startup
scripts (Free)), or run as-is on a freshly installed UTM VM / physical
box. It installs Ansible and uses `ansible-pull` to fetch this repo
and run [`site.yml`](site.yml) against the local machine -- no inbound
SSH or separate control node required.

Edit the variables at the top of [`bootstrap.sh`](bootstrap.sh) first
(install method, repo URL/ref overrides, deploy key if needed), then
paste the whole script in. You do **not** need to touch
`inventory/hosts.ini` for this method --
[`bootstrap.sh`](bootstrap.sh) passes `-i "localhost,"` explicitly,
which overrides whatever's (or isn't) in that file. It exists purely
for [Method 1](#method-1-control-node-pushes-to-a-target-over-ssh).
[Method 2](#method-2-run-directly-on-the-target-no-ssh) above is the
better fit if you're already logged into the box and just want to run
things interactively instead of pasting a pre-filled script.

## Private repo access

Only relevant under `rivolution_install_method: source`, pointed at
your own private fork -- the `deb` method (public default) needs none
of this. `rivolution_deploy_key_path` (in
[`group_vars/all.yml`](group_vars/all.yml), or passed via
`-e`/[`bootstrap.sh`](bootstrap.sh)) is a path to a private SSH key
file with read access to `rivolution_git_repo` -- a file path, not the
key content itself, since passing multi-line PEM content directly as
an extra-var value doesn't survive Ansible's CLI parsing. When set, the
[`deploy_key` role](https://github.com/anjeleno/rivolution-unified-installer/tree/main/roles/deploy_key)
copies it into the install user's `~/.ssh/`, scoped to `github.com`
only via `~/.ssh/config` so it's never used for anything else. Leave
it blank if your repo is public, or if the box already has working git
credentials some other way (e.g. you're running this from your own
machine with an agent already forwarding your normal key).

**Never commit a real key into this repo.** Pass it at runtime, ideally
via an Ansible Vault file (`ansible-playbook site.yml -e @secrets.yml
--ask-vault-pass`) rather than plain `-e` on the command line where
it'd show up in shell history.

## Install modes

`rivolution_install_mode` (default `standalone`) picks one of three
shapes, applied by driving the dashboard's own `/mode` page over HTTP
(the same mechanism a human clicking through `/mode` uses) once
Rivolution is installed and its dashboard is up -- not a second,
separate NFS/database implementation. See
[`docs/specs/0004`](docs/specs/0004-deb-based-provisioning.md) for why.

- **standalone** -- everything local: database, audio store, desktop.
- **server** -- standalone, plus the database and audio store exposed
  to other Rivolution hosts over NFS.
- **client** -- only the Rivolution application itself, pointed at a
  remote MySQL/MariaDB host and a remote NFS-mounted audio store
  instead of provisioning either locally. Needs
  `rivolution_remote_mysql_host`/`_user`/`_database`/
  `_password_path` and `rivolution_remote_nfs_host` set.

## Tailscale

`rivolution_tailscale_enabled` (default `false`) installs the
`tailscale` package and enables (but does not start) `tailscaled`,
plus a scoped sudoers grant for the install user to run `tailscale
up`/`cert`/`status`. Leave `rivolution_tailscale_authkey_path` blank to
activate it yourself later (`sudo tailscale up`, or eventually the
dashboard's own Network page -- see
[the main repo's `BACKLOG.md`](https://github.com/anjeleno/rivolution/blob/main/BACKLOG.md)),
or point it at a file containing a real auth key to activate
immediately during provisioning.

## Security hardening

`rivolution_harden_security` (default `false`) installs `ufw`
(allowing Icecast's port, SSH, and the optional
`rivolution_harden_external_ip`/`rivolution_harden_lan_subnet`), then
disables SSH password authentication, but only if an `authorized_keys`
file already exists for the install user. If one doesn't exist yet, SSH
hardening is skipped with a warning rather than risking a lockout.
Deliberately does **not** open the dashboard (`rivapi`, port 8080) or
Stereo Tool's web UI (port 8079) to the public -- Tailscale, above, is
the intended way to reach those remotely.

## What's intentionally not automated

- Phase 0 (creating the Droplet / installing a base OS on a UTM VM or
  physical box) -- this playbook starts from "fresh Ubuntu 24.04/26.04,
  reachable as root," not before.
- Disk imaging/cloning a literal golden image (`dd`, streaming over
  SSH, importing into UTM) -- this playbook is the replacement for
  that workflow, not an addition to it. Run it fresh on each target
  instead of cloning a disk image.
- Per-station configuration inside Rivolution itself (Dropboxes, carts,
  schedule codes, RDAdmin host settings, broadcast streams on
  `/broadcast`) -- this gets you to a running station with a test tone
  in the library, not a configured one.
- The one remaining manual browser step `debian/postinst` itself calls
  out at the end of every install: opening the dashboard's `/patchbay`
  page and connecting/saving the `caed` -> Stereo Tool -> stream audio
  chain. Deliberately left as a real operator action, not scripted
  around -- see `docs/specs/0004`.

## Re-running this playbook later

Most of this is safe to re-run (it'll just confirm the existing state
and move on -- `apt` itself is the idempotency mechanism for actually
installing Rivolution, both for a downloaded release and a locally
built one). One step is guarded by its own marker file instead, the
same way `roles/desktop` already auto-skips installing a desktop
that's already there:

- **`rivolution_install_method: source`'s local build**: once
  `/etc/rivolution-build-provisioned` exists, the clone/build steps are
  skipped entirely on every later run, even if the source checkout
  itself was deleted or reset in the meantime. Delete that marker
  yourself if you genuinely want to force a rebuild (e.g. to pick up a
  new `rivolution_git_ref`). If you do, and the checkout still exists
  with uncommitted local changes -- a previous manual build, hand edits
  while debugging -- the build role refuses to touch it and fails with
  a clear message instead of silently discarding them; back up or
  remove that checkout yourself, or re-run with
  `-e rivolution_build_force_clean=true` (see
  [`group_vars/all.yml`](group_vars/all.yml)) to have it discard those
  changes and clone fresh.
