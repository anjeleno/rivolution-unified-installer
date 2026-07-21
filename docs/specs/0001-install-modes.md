# 0001 — Standalone/Server/Client install modes

**Date:** 2026-06-20

**Partially superseded 2026-07-20 by
[0004-deb-based-provisioning.md](0004-deb-based-provisioning.md)**:
the three modes and their variable names described here are unchanged,
but the *mechanism* isn't — server/client topology switching now goes
through the dashboard's own `/mode` page (driven over HTTP from
Ansible), not the NFS/`fstab` tasks this spec originally called for.
Kept as historical record of the original design; see 0004 for what's
actually implemented today.

## Goal

This playbook currently only produces one shape of install: everything
local (MariaDB, audio store, desktop/xrdp) — closest to Paravel's own
"Standalone" mode, plus dev conveniences (desktop, xrdp) on top. Add
the other two modes Paravel's own installer supports, so this playbook
can provision any of the three, not just the golden-image/dev shape:

- **Standalone** (existing default, unchanged): everything local.
- **Server**: everything Standalone does, *plus* the database and
  audio store exposed to other Rivendell systems over the network.
- **Client**: only the Rivendell application itself — no local
  database, no local audio store — pointed at a remote MySQL/MariaDB
  host and a remote NFS-mounted audio store.

## Background — verified against the real installer, not the wrapper

The user-facing `install_rivendell.sh` script is just a menu — it adds
Paravel's apt repo and delegates to
`/usr/share/ubuntu-rivendell-installer/installer_install_rivendell.sh`,
which lives inside the `ubuntu-rivendell-installer` `.deb` package, not
in the wrapper itself. Fetched and read the real package directly
(`https://software.paravelsystems.com/ubuntu/dists/noble/main/binary-amd64/ubuntu-rivendell-installer_1.1.0noble-1_all.deb`,
extracted via `dpkg-deb -x` without installing it — no footprint left
on any system) rather than guess from the wrapper's menu text.

### What actually differs between the three modes

All three first install a common package set (`openssh-server`,
`samba`, `nfs-common`, `autofs`, `libmad0`/`libtwolame0`/`libmp3lame0`,
etc.), then diverge:

- **Standalone**: installs `mariadb-server` locally; creates the
  database and a `rduser` grant scoped to `localhost` only; enables
  Samba file sharing; creates the local `music_export`/
  `music_import`/`traffic_export`/`traffic_import`/`rd_xfer`
  directories; runs `rddbmgr --create --generate-audio` locally.
- **Server**: everything Standalone does, *plus* grants `rduser`
  access from `'%'` (any host) in addition to `localhost`; installs
  `nfs-kernel-server`; bind-mounts `/var/snd` and all the same
  directories under `/srv/nfs4/`; adds them to `/etc/exports`
  (`*(rw,no_root_squash)`).
- **Client**: skips MariaDB and the local audio store entirely —
  installs only the Rivendell application packages; configures
  `autofs` (`/etc/auto.rd.audiostore`, templated with the remote NFS
  host's IP) and symlinks `/home/rd/{rd_xfer,music_export,
  music_import,traffic_export,traffic_import}` into the
  autofs-managed `/misc/*` mount instead of creating them locally.

All three then build `/etc/rd.conf` from a template with
`%MYSQL_HOSTNAME%`/`%MYSQL_LOGINNAME%`/`%MYSQL_PASSWORD%`/
`%NFS_MOUNT_SOURCE%`/`%NFS_MOUNT_TYPE%` placeholders — directly
analogous to what this playbook's own
`roles/provision/templates/rivolution-first-run.sh.j2` already does for
`/etc/rd.conf`, just with more placeholders to fill in.

### A real simplification versus the original: no per-mode build split needed

Paravel's installer differentiates *which packages* get installed per
mode, because their `.deb` packaging splits cleanly along those lines.
This playbook builds everything from source uniformly — `make install`
puts down the same binaries regardless of mode, there's no "client-only
build subset" to carve out. So unlike the original, the `build` role
needs **no mode-awareness at all** — only what gets *configured*
afterward (where the database lives, where the audio store lives)
differs. This meaningfully narrows the actual diff needed here.

## Implementation plan

### 1. New group_vars (`group_vars/all.yml`)

```yaml
rivendell_install_mode: standalone  # standalone | server | client

# Only consulted when rivendell_install_mode == client
rivendell_remote_mysql_host: ""
rivendell_remote_mysql_user: "rduser"
rivendell_remote_mysql_password: ""
rivendell_remote_mysql_database: "Rivendell"
rivendell_remote_nfs_host: ""
```

Defaulting to `standalone` preserves every existing behavior for
anyone not setting this — the golden-image/dev build keeps working
exactly as it does today with zero config changes.

### 2. `database` role: gate by mode, widen the grant for `server`

- Wrap the existing `mariadb-server` install + grant tasks in
  `when: rivendell_install_mode in ['standalone', 'server']` — client
  mode skips this role entirely.
- For `server` mode specifically, add the second grant
  (`'rduser'@'%'`) alongside the existing `localhost` one — mirrors
  `AddDbUser` being called twice in the real installer for server
  mode, once per host pattern.

### 3. New NFS-export tasks, server-only

A new task file (or a `when`-gated block in an existing role) that
only runs for `rivendell_install_mode == server`:

- Install `nfs-kernel-server`.
- Create and bind-mount `/srv/nfs4/var/snd` and the
  `music_export`/`music_import`/`traffic_export`/`traffic_import`/
  `rd_xfer` directories under `/home/{{ rivendell_user }}/`, exactly
  mirroring the real installer's `/etc/fstab` bind-mount entries.
- Add the matching `/etc/exports` entries
  (`*(rw,no_root_squash)`, matching the original exactly — revisit if
  tighter NFS access control is wanted later; out of scope for this
  pass, see below).

### 4. New NFS-client/autofs tasks, client-only

Only for `rivendell_install_mode == client`:

- Install `autofs`.
- Template `/etc/auto.rd.audiostore` with
  `rivendell_remote_nfs_host`'s IP standing in for the original's
  `@IP_ADDRESS@` placeholder.
- Symlink `/home/{{ rivendell_user }}/{rd_xfer,music_export,
  music_import,traffic_export,traffic_import}` into the
  autofs-managed `/misc/*` mount, replacing (not supplementing) the
  directories Standalone/Server create locally.
- Skip `roles/database` and the new server-only NFS-export tasks
  entirely (already covered by item 2's `when` gate).

### 5. `provision` role (`rivolution-first-run.sh.j2`): mode-aware `rd.conf`

This template currently always points `rd.conf` at a locally-generated
password and `localhost`. Needs to branch:

- `standalone`/`server`: keep the existing behavior exactly as-is —
  generate a random password locally, point at `localhost`.
- `client`: skip the local password generation and `rddbmgr --create
  --generate-audio` call entirely (there's no local database to
  create); instead populate `rd.conf`'s `[mySQL]` section from
  `rivendell_remote_mysql_host`/`_user`/`_password`/`_database`
  directly.

## Confirmed out of scope for this pass

- Building separate `.deb` packages per mode — that's the *other*,
  separate pre-built-binary-packaging conversation; this spec is only
  about what the Ansible playbook itself configures, still building
  from source for every mode.
- Samba/CIFS file sharing — the real installer enables this for both
  Standalone and Server; not part of this playbook's stated scope
  (radio automation install, not a general file-sharing appliance) and
  not requested. Can be added later as its own spec if wanted.
- Tightening the original's NFS export permissions
  (`*(rw,no_root_squash)`, exporting to any host) — matched as-is for
  parity with the original installer's behavior; flagging here as a
  real, pre-existing security looseness worth a future pass, not
  something to quietly fix as a side effect of this spec.

## Resolved decisions (2026-06-20)

- **`roles/desktop` (MATE/xrdp) runs unconditionally for all three
  modes**, not just standalone/server. The original installer skips a
  desktop for Client mode since it targets existing on-air/production
  hardware — deliberately not followed here: the goal is drop the
  bootstrap on any virtual or physical box and get a fully working,
  zero-touch build consistent with the rest of this project's dev
  setup either way. Building from source or pulling a `.deb` package
  remain the path for anyone who wants to customize that.
- **NFS export permissions stay as the original installer's**
  (`*(rw,no_root_squash)`, exported to any host) — not tightened in
  this pass. Real-world use is already behind a Tailscale network;
  baking Tailscale-aware export restrictions in is a real idea for
  later, not part of this spec.
- **`RIVENDELL_REMOTE_MYSQL_HOST`/`_USER`/`_PASSWORD`/`_DATABASE` and
  `RIVENDELL_REMOTE_NFS_HOST` fields added to `bootstrap.sh`**,
  elaborated below — mirrors the existing `RIVENDELL_DEPLOY_KEY`
  pattern for the password specifically, plain `-e` extra-vars for the
  rest.

### Elaboration: the `bootstrap.sh` change, concretely

New fields alongside the existing ones in the "EDIT THESE" block:

```bash
# Only used when rivendell_install_mode=client (see group_vars/all.yml
# in the installer repo) -- a remote MySQL/MariaDB host and the audio
# store's NFS host to point this box at, instead of provisioning
# either locally.
RIVENDELL_REMOTE_MYSQL_HOST=""
RIVENDELL_REMOTE_MYSQL_USER="rduser"
RIVENDELL_REMOTE_MYSQL_PASSWORD=""
RIVENDELL_REMOTE_MYSQL_DATABASE="Rivendell"
RIVENDELL_REMOTE_NFS_HOST=""
```

**A real bug to design around, not just copy-paste the existing
pattern twice:** `bootstrap.sh` currently calls `trap '...' EXIT`
*inside* the `RIVENDELL_DEPLOY_KEY` block. Bash's `trap` *replaces* the
previous handler for a signal rather than adding to it — calling
`trap` a second time for the password's temp file would silently drop
the deploy key's cleanup. Fix: hoist to a single combined trap that
both blocks append to, set once before either conditional runs:

```bash
extra_vars=()

# Temp files created below are tracked here and cleaned up by one
# combined trap -- calling `trap ... EXIT` more than once replaces the
# previous handler rather than adding to it, so each secret below
# appends to this array instead of setting its own trap.
cleanup_paths=()
cleanup() { rm -f "${cleanup_paths[@]}"; }
trap cleanup EXIT

[ -n "$RIVENDELL_GIT_REPO" ] && extra_vars+=(-e "rivendell_git_repo=$RIVENDELL_GIT_REPO")
[ -n "$RIVENDELL_GIT_REF" ] && extra_vars+=(-e "rivendell_git_ref=$RIVENDELL_GIT_REF")
[ -n "$RIVENDELL_HOSTNAME" ] && extra_vars+=(-e "rivendell_hostname=$RIVENDELL_HOSTNAME")

if [ -n "$RIVENDELL_DEPLOY_KEY" ]; then
  deploy_key_path="$(mktemp)"
  chmod 600 "$deploy_key_path"
  printf '%s\n' "$RIVENDELL_DEPLOY_KEY" > "$deploy_key_path"
  cleanup_paths+=("$deploy_key_path")
  extra_vars+=(-e "rivendell_deploy_key_path=$deploy_key_path")
fi

[ -n "$RIVENDELL_REMOTE_MYSQL_HOST" ] && extra_vars+=(-e "rivendell_remote_mysql_host=$RIVENDELL_REMOTE_MYSQL_HOST")
[ -n "$RIVENDELL_REMOTE_MYSQL_USER" ] && extra_vars+=(-e "rivendell_remote_mysql_user=$RIVENDELL_REMOTE_MYSQL_USER")
[ -n "$RIVENDELL_REMOTE_MYSQL_DATABASE" ] && extra_vars+=(-e "rivendell_remote_mysql_database=$RIVENDELL_REMOTE_MYSQL_DATABASE")
if [ -n "$RIVENDELL_REMOTE_MYSQL_PASSWORD" ]; then
  # Same file-path treatment as the deploy key, and for the same
  # reason: passing a real secret as -e content directly would put it
  # in `ps aux` output and potentially in Ansible's own verbose
  # logging. The multi-line-PEM parsing bug doesn't apply to a
  # password, but the exposure risk does.
  mysql_password_path="$(mktemp)"
  chmod 600 "$mysql_password_path"
  printf '%s\n' "$RIVENDELL_REMOTE_MYSQL_PASSWORD" > "$mysql_password_path"
  cleanup_paths+=("$mysql_password_path")
  extra_vars+=(-e "rivendell_remote_mysql_password_path=$mysql_password_path")
fi
[ -n "$RIVENDELL_REMOTE_NFS_HOST" ] && extra_vars+=(-e "rivendell_remote_nfs_host=$RIVENDELL_REMOTE_NFS_HOST")
```

**Consumption on the Ansible side differs from the deploy key, not
just the variable name.** `rivendell_deploy_key_path` is consumed as a
path — the `deploy_key` role copies that *file* into `~/.ssh/`
directly, never reads its contents into a variable. A MySQL password
needs to become a *string* to template into `rd.conf`'s `[mySQL]`
section, so the role consuming it needs an explicit read step:

```yaml
- name: Read the remote MySQL password from its file
  ansible.builtin.set_fact:
    rivendell_remote_mysql_password: "{{ lookup('file', rivendell_remote_mysql_password_path) }}"
  when: (rivendell_install_mode == 'client') and (rivendell_remote_mysql_password_path | default('') != '')
```

`group_vars/all.yml` gets `rivendell_remote_mysql_password_path: ""`
instead of (or alongside, defaulting empty) the plain
`rivendell_remote_mysql_password` placeholder shown in item 1's
group_vars block above — the path is what actually arrives from
`bootstrap.sh`; the plaintext variable only exists transiently after
the `lookup('file', ...)` step runs.

