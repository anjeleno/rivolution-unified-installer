# 0004 — Install via the released `.deb`, not a from-source build every run

**Date:** 2026-07-20

## Goal

Rewrite this playbook around installing Rivolution's own released
`.deb` package as the default path, instead of cloning and compiling
from source on every run. Keep a from-source path available
(`rivolution_install_method: source`), but design it so it costs almost
nothing extra to maintain — not a second, parallel provisioning
implementation. Fold in everything this repo has fallen behind on since
it was last substantially touched (2026-07-10), consolidated from the
main repo's `docs/specs/` 0007/0008/0010/0011/0014/0015,
`debian/control.src`/`debian/postinst`/`scripts/rivolution-first-run.sh`,
`BACKLOG.md`, and every handoff doc/private note that ever discussed
this repo.

## Why

This playbook still built Rivolution from source on every run (git
clone + `configure_build.sh` + `make`, 15-30 minutes) and provisioned
almost nothing past core Rivendell — no PipeWire, no `rivapi`
dashboard, no Stereo Tool infra, no broadcast-stack systemd units, no
sudoers, no udev, no `.asoundrc`. `debian/postinst` now automates
essentially all of that in one comprehensive, idempotent pass — and
critically, **`scripts/rivolution-first-run.sh`, the script this
playbook's old `roles/provision` called directly, does not** (confirmed
by reading it directly: its own header comment says outright that
`postinst` covers everything it does plus the entire broadcast/
PipeWire/`rivapi` layer it doesn't). A from-source build never got that
provisioning automatically — this playbook's old `roles/database`,
`roles/broadcast_tools`, `roles/webserver`, and `roles/provision` were
each independently, incompletely trying to catch up to what `postinst`
already does properly in one place.

This repo has fallen behind the main repo's own changes three separate
times chasing exactly this kind of gap (Liquidsoap→ffmpeg twice, the
`broadcast_advanced` role removal) — each time because it duplicated
logic that lives, better-maintained, somewhere else. The main repo's
own spec 0010 names this fork explicitly as undecided: *"Whether the
unified installer still needs its own role for package installation +
conf placement, or should simply install the Debian package below once
it exists, is an open question."* This spec decides it.

A second, independent bug reinforces the same lesson: the old
`roles/database`'s client-mode NFS mount never reliably landed in
`fstab`, found live 2026-06-30, never root-caused (the run's logs were
lost each time it was chased). The dashboard's `/mode` page (shipped
2026-07-04) is a from-scratch, better-tested reimplementation of the
same switching — CHANGELOG's own words: *"replacing what used to
require a full Ansible re-provision."* Rather than diagnose a bug with
no repro data and maintain a second implementation indefinitely, this
spec drives `/mode`'s own mechanism from Ansible instead of
re-implementing it.

## Decision: `.deb` default, `source` a genuinely cheap opt-in

The fix is not "teach Ansible to replicate `postinst`'s steps a second
time" — that recreates the exact duplication problem above. It's:
**build a local `.deb` from a fresh source checkout (`dpkg-buildpackage`,
via the main repo's own `scripts/rebuild-deb.sh --no-bump`) instead of
running `make install` directly, then install that local `.deb` through
the identical `apt install <path>` step the download path already
uses.** `postinst` then runs either way, unmodified, from the one place
it's actually maintained. The only genuinely new/duplicated maintenance
surface `source` costs is the build-dependency package list in
`roles/base` (low-churn, gated behind `rivolution_install_method ==
"source"`, cross-checked periodically against the wiki's
`Build-From-Source.md`) — not provisioning logic.

`rivolution_install_method`:
- **`deb`** (default) — download the matching release asset from
  GitHub Releases and install it.
- **`source`** — clone `rivolution_git_repo`/`rivolution_git_ref`,
  build a local `.deb`, install that instead.

## Decision: `/mode`'s own HTTP API, not a second NFS implementation

`rivolution_install_mode` (`standalone`/`server`/`client`, same three
values and same remote-host/credential variable names this playbook has
always had) is still a real, settable option — kept because a
single-command, unattended "stand up a whole client station pointed at
a known server" rollout is a genuine use case. What changed is *how*
it's applied: `roles/mode_apply` waits for the dashboard to come up,
logs in, and `POST`s to `/mode/apply` — the exact mechanism a human
clicking through `/mode` uses (`rivapi/dashboard/handlers_mode.go`),
including its own re-authentication gate (`confirm_password`, the same
dashboard credential `/login` already checks). This can never drift out
of sync with `/mode` since it *is* `/mode`, and it retires the
never-diagnosed `roles/database` bug by not re-implementing the thing
that was broken.

## Decision: Tailscale role now, dashboard activation later

The main repo's spec 0014 designs Tailscale as three pieces: an Ansible
role (install + enable, opt-in), a dashboard "Network" page (auth-key
activation, MagicDNS/status, TLS cert), and TLS-serving support in
`rivapi`. As of this writing, **none of the three exist**. This spec
builds the Ansible role now — `rivolution_tailscale_enabled` (default
`false`) installs and enables (not starts) `tailscaled` plus the
sudoers grant spec 0014 already specifies; `rivolution_tailscale_authkey_path`
(a file path, same secret-handling pattern as the remote MySQL
password) optionally activates it immediately
(`tailscale up --auth-key=...`). This is safe to ship ahead of the
dashboard half — nothing downstream depends on it yet, and it means
this playbook is ready the moment that page lands instead of needing
its own follow-up pass. The dashboard Network page itself is out of
scope here — tracked in the main repo's `BACKLOG.md` as part of an
`rc1-3` candidate sweep.

## Decision: `AUDIO_CARDS.DRIVER` provisioning, closing a same-day gap

Found while diagnosing a live Stereo Tool failure the same day this
spec was written: nothing in `postinst` sets `AUDIO_CARDS.DRIVER` to
JACK — every working box got that by hand via RDAlsaConfig (deselecting
every listed ALSA device, or finding none listed at all, then Save).
`roles/desktop` already gathers exactly the real/virtual hardware facts
this fork needs to make that same call (HPI presence, virtualization,
ALSA card presence — spec 0003). `roles/audio_provisioning`, new in
this spec, applies it directly: once real HPI hardware is ruled out,
`AUDIO_CARDS.DRIVER` is set to `2` (Jack, per `RDStation::AudioDriver`'s
enum) for card 0 via a direct database write, using the credentials
`postinst` already generated into `/etc/rd.conf`. This closes the main
repo's `BACKLOG.md` "Fresh installs never provision a working audio
card" entry for Ansible-provisioned installs specifically — the
general, non-Ansible fix (an equivalent probe inside `postinst` itself)
stays tracked there separately.

**Forward-pointer, worth re-reading before touching either side
again:** if/when that general `postinst` fix lands, revisit
`roles/audio_provisioning` — it may become fully redundant, or need to
shrink to whatever gap remains between what `postinst` can determine at
package-install time and what Ansible additionally knows from its own
OS-level facts. Don't let this quietly duplicate `postinst` once
`postinst` can do it too.

## Decision: `/root/.Xauthority` moves to `debian/postinst`, not this repo

Originally planned as an Ansible-only task (unconditional, alongside
xRDP installation). Reworked after checking directly: Ubuntu's stock
PAM stack has no `pam_xauth` module anywhere (`grep -rl pam_xauth
/etc/pam.d/` → no hits, checked on a real box) — there is no automatic
mechanism that hands root a copy of the install user's X11 cookie on
`sudo`, on *any* Ubuntu install, physical or virtual. `sudo
rdalsaconfig`/`rddbconfig` therefore fails the identical X11/xcb
authorization error everywhere, not just under xrdp (xrdp just makes it
visible first, since a virtual session has no separate physical console
to silently mask the same problem). Since the need is universal — every
install path, not just Ansible-provisioned ones — the fix belongs in
`debian/postinst`, next to its existing `getent passwd rd` block (the
same one that deploys `~/.asoundrc`), not duplicated here. `roles/desktop`
keeps installing the xRDP *packages* (a genuine installer-level choice)
but no longer creates this symlink itself. Tracked as a real,
already-applied change in the main repo — see its own `BACKLOG.md` and
`CHANGELOG.md` for the actual fix.

## New role architecture

`site.yml` order:

```yaml
roles:
  - base
  - desktop
  - deploy_key      # source method only, no-op under deb
  - build            # source method only: builds a local .deb
  - rivolution_deb    # installs a .deb, downloaded or local
  - audio_provisioning
  - mode_apply
  - tailscale           # opt-in
  - security_hardening
```

- **`roles/base`** — hostname/`/etc/hosts`, timezone (new:
  `rivolution_timezone`), NTP, user creation, OS detection,
  best-effort `linux-modules-extra`. Build-toolchain/Qt6/DocBook
  package list moved behind `rivolution_install_method == "source"`.
- **`roles/desktop`** — MATE-if-absent (unchanged), audio-hardware
  detection (unchanged, spec 0003), plus a new
  `rivolution_use_jack_driver` fact derived from the same detection
  results, consumed by `audio_provisioning`. No longer creates the
  `/root/.Xauthority` symlink (moved to `debian/postinst`, see above).
- **`roles/build`** — source method only. Clones the source tree (same
  local-changes safety check as before), runs `scripts/rebuild-deb.sh
  --no-bump` to produce a local `.deb` instead of `make install`,
  records its path for `roles/rivolution_deb`.
- **`roles/rivolution_deb`** (new) — under `deb` method, resolves the
  release (latest, or a pinned `rivolution_release_tag`) via GitHub's
  Releases API, picks the matching asset for this host's
  architecture/OS version, downloads it. Under `source` method, uses
  `roles/build`'s output instead. Either way: `ansible.builtin.apt:
  deb=<path>` — naturally idempotent, and the only place this repo
  actually installs Rivolution.
- **`roles/audio_provisioning`** (new) — see "Decision: AUDIO_CARDS.DRIVER"
  above.
- **`roles/mode_apply`** (new, replaces `roles/database`) — see
  "Decision: `/mode`'s own HTTP API" above.
- **`roles/tailscale`** (new, opt-in) — see "Decision: Tailscale role"
  above.
- **`roles/security_hardening`** — unchanged. Deliberately does not
  open `rivapi`'s dashboard port (8080) or Stereo Tool's web UI (8079)
  to the public `ufw` allow list — Tailscale is the intended remote-
  access path for those.
- **`roles/deploy_key`** — unchanged, scoped to `rivolution_install_method
  == "source"` (meaningless under `deb`, which never clones anything).
- **Retired**: `roles/database` (see above), `roles/broadcast_tools`
  (the `.deb`'s own `Depends` already pulls in Icecast/ffmpeg/fdkaac/
  VLC/PipeWire/etc.), `roles/webserver` (`postinst` already wires up
  Apache/`cgid`/`rdxport.cgi`), `roles/provision` (`postinst` already
  does everything this used to hand-orchestrate — including a task that
  patched a `pypad.py` bug confirmed, via `grep`, to no longer exist in
  current source at all; simply deleted, not migrated).

## Requirements checklist: what `debian/postinst` already covers

Re-diff against `debian/postinst` itself when this is next revisited —
not against this list, which will go stale. As of this writing,
`postinst` handles, in order: the `pipewire-jack` `ld.so.conf.d`
ordering fix; `rd`'s `audio`/`rivendell` group membership and
`~/.asoundrc` deployment; legacy `rivendell`/`pypad` system accounts;
`/var/snd` ownership/permissions; `/etc/rd.conf` (symlinked from
`/etc/rivendell.d/rd-default.conf`); `/etc/profile.d/rivendell-env.sh`;
fresh-install database provisioning (random MySQL password + JWT
secret, database/user/grants, `rddbmgr --create --generate-audio`) or
upgrade migration (`rddbmgr --modify`); PulseAudio disable +
`@audio`/`rtprio`/`memlock` limits; every broadcast-stack systemd unit
and drop-in (`rivolution-stack.target`, `pipewire-system.service`,
`wireplumber-system.service`, `stereo-tool.service`, `rivapi.service`,
the `rivendell.service.d`/`icecast2.service.d` drop-ins), decommissioning
any leftover pre-0015 `liquidsoap.service`; `/etc/sudoers.d/rivapi`;
`/etc/udev/rules.d/99-ptp.rules`; enabling `pipewire-system`/
`wireplumber-system` before restarting `rivendell.service`; enabling
`rivapi.service`/`rivolution-stack.target`; Apache `cgid` + `rdxport.cgi`
setuid; icon cache refresh; the WebGet logo; `/var/log/rivendell` +
rsyslog config; `rdselect_helper`/`webget.cgi` setuid. Not covered:
`linuxptp` (spec 0007 calls for it; absent from `debian/control.src`'s
`Depends` — a real, separately-tracked gap, not this playbook's to
fix), Tailscale (deliberately this playbook's job, not `postinst`'s —
see above), and the one deliberately-manual `/patchbay` step (see
"Non-goals" below).

## `group_vars` — every variable

| Variable | Default | Controls |
|---|---|---|
| `rivolution_user` | `rd` | Install/desktop account name |
| `rivolution_home` | `/home/{{ rivolution_user }}` | Derived home path |
| `rivolution_hostname` | `{{ inventory_hostname }}` | Target hostname; skipped for literal `"localhost"` |
| `rivolution_timezone` | `""` | System timezone; blank skips |
| `rivolution_install_method` | `deb` | `deb` \| `source` |
| `rivolution_release_tag` | `""` | `deb` method: pin an exact release tag; blank = latest |
| `rivolution_git_repo` | `https://github.com/anjeleno/rivolution.git` | `source` method: repo to clone |
| `rivolution_git_ref` | `main` | `source` method: ref to build |
| `rivolution_build_force_clean` | `false` | `source` method: discard local checkout changes instead of failing |
| `rivolution_audio_kernel_module` | `""` (auto-detect) | Explicit kernel-module override |
| `rivolution_target_os` | auto-detected | `debian` \| `ubuntu` |
| `rivolution_install_mode` | `standalone` | `standalone` \| `server` \| `client`, applied via `/mode` |
| `rivolution_remote_mysql_host`/`_user`/`_password_path`/`_database` | blank / `rduser` / blank / `Rivendell` | `server`/`client` mode remote DB |
| `rivolution_remote_nfs_host` | `""` | `server`/`client` mode remote audio store |
| `rivolution_tailscale_enabled` | `false` | Opt-in Tailscale install |
| `rivolution_tailscale_authkey_path` | `""` | File path to an auth key; blank = install/enable only |
| `rivolution_harden_security` | `false` | Opt-in `ufw` + SSH key-only |
| `rivolution_harden_external_ip`/`_lan_subnet` | `""` | Extra `ufw` allow rules |
| `rivolution_deploy_key_path` | `""` | `source` method, private fork: SSH deploy key path |

## Non-goals (unchanged from the original README, reaffirmed)

Per-station configuration (Dropboxes, carts, schedule codes, RDAdmin
host settings, broadcast streams on `/broadcast`), disk imaging/golden-
image cloning, and the one remaining manual browser step — opening
`/patchbay` and connecting/saving the audio chain, which `postinst`'s
own final message already calls out. This spec does not script around
that; scripting it would mean silently deciding per-station audio
routing on an operator's behalf.

## Known limitations

**No Debian-built `.deb` release target exists.** Only `amd64`,
`amd64-noble`, and `arm64` release assets are published today, all
built from Ubuntu. `rivolution_install_method: deb` therefore cannot
target Debian Trixie until the main repo's release CI
(`.github/workflows/build-deb.yml`) adds a Debian leg —
`rivolution_install_method: source` is unaffected (it builds locally,
matching spec 0002's original ARM64+Debian intent) and is the only way
to install on Debian today. Tracked as a real, separate action item in
the main repo's `BACKLOG.md`, not something this playbook works around.

**The xRDP/`.Xauthority` fix (moved to `debian/postinst`, see above) is
config-level verified, not end-to-end verified on real physical
hardware.** Confirmed directly that Ubuntu's stock PAM stack has no
`pam_xauth` module (so the fix is genuinely needed everywhere, not just
under xrdp) and that a fresh box has nothing pre-existing for the
symlink task to conflict with — but the live flow (a real person, on a
real physical desktop, running `sudo rdalsaconfig` after this lands)
hasn't been tested on genuine physical hardware. Worth confirming
whenever that's next available.

## Verification

Tested end to end by Brandon: locally in a UTM container (matching the
original golden-image workflow) and on a real DigitalOcean droplet —
covering both the "local" and "SSH control-node" provisioning methods,
and both `deb` (default) and `source` install methods.
