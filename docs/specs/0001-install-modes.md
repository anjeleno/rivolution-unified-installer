# 0001 — Standalone/Server/Client install modes

**Date:** 2026-06-20

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
`roles/provision/templates/fix-rivendell-user.sh.j2` already does for
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

### 5. `provision` role (`fix-rivendell-user.sh.j2`): mode-aware `rd.conf`

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

## Open items for implementation time

- Where `rivendell_remote_mysql_password` gets supplied for client
  mode at runtime — should mirror the existing
  `rivendell_deploy_key_path` convention (passed via `-e` or an
  Ansible Vault file, never committed), not a new pattern.
- Confirm whether `roles/desktop` (MATE/xrdp) should still run
  unconditionally for all three modes, or only for
  standalone/server — Client mode in the original installer doesn't
  install a desktop at all, since it's meant to run on existing
  on-air/production hardware, not be RDP'd into for development.
