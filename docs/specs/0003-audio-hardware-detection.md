# 0003 — Automatic audio hardware/environment detection

**Date:** 2026-06-23

**Extended 2026-07-20 by
[0004-deb-based-provisioning.md](0004-deb-based-provisioning.md)**:
the kernel-module detection described here (`roles/desktop`) is
unchanged and still the mechanism in use. 0004 adds a second, related
piece on top — actually setting Rivolution's own `AUDIO_CARDS.DRIVER`
to JACK using these same detection results (`roles/audio_provisioning`),
closing the separate, longer-standing gap where nothing did that
automatically even when the kernel module was already correctly
detected.

## Goal

Replace the single hardcoded `rivendell_audio_kernel_module` default
with real per-host detection of what audio environment this install is
actually running in — AudioScience HPI hardware, generic ALSA
hardware, a UTM/QEMU VM, or a headless cloud box with no audio device
at all — so the playbook stops assuming every target looks like the
UTM/cloud-hypervisor case it was originally written against.

## Background

### The UTM/cloud case, confirmed against the manual build log

Checked `~/Documents/Docs/golden-image.md` (the manual build log this
playbook was derived from) directly, rather than relying on memory of
what the original manual steps were. The full sequence, already
implemented in this playbook today, not just in the manual log:

1. **Package**: `linux-modules-extra-{{ ansible_kernel }}` —
   `roles/base/tasks/main.yml`. On a minimal/cloud Ubuntu kernel,
   `snd_hda_intel` (the module UTM's emulated Intel HDA audio device
   needs) isn't in the base kernel package, only in
   `linux-modules-extra` — without it, `modprobe snd_hda_intel` fails
   with "module not found."
2. **Load now**: `modprobe snd_hda_intel` —
   `roles/desktop/tasks/main.yml`, "Load the audio kernel module now."
3. **Persist across reboots**: writes the module name to
   `/etc/modules-load.d/rivendell-audio.conf` —
   `roles/desktop/tasks/main.yml`, "Load the audio kernel module on
   every boot."
4. **A related but distinct gotcha, also in golden-image.md**:
   `/dev/snd/*` is group-`audio`-owned; without `usermod -aG audio rd`
   (also already in `roles/desktop/tasks/main.yml`), `caed`/`aplay`
   report "no soundcards found" even though `/proc/asound/cards` shows
   the card is there. Requires a logout/login or reboot to take
   effect — group membership doesn't apply to an already-open session.

`group_vars/all.yml` already names the module as an overridable
variable (`rivendell_audio_kernel_module: snd_hda_intel`, with a
comment noting it "matches the Intel HDA device emulated by UTM/most
cloud hypervisors... override per-host for physical hardware with a
different chipset"). So the mechanism for *changing* the module per
host already exists — what's missing is automatic *detection*, which
is this spec's actual scope.

### The deployment shapes this needs to distinguish

- **AudioScience HPI hardware** — a proprietary vendor driver, not a
  generic ALSA `snd_*` module at all. Detection needs to *not* force
  any ALSA kernel module in this case — forcing `snd_hda_intel` (or
  anything else) onto an HPI box would be actively wrong, not just
  unnecessary or harmless.
- **Generic ALSA hardware (real, non-virtualized)** — the kernel
  normally auto-detects and loads the correct `snd_*` driver itself via
  udev/kmod, with no manual `modprobe` needed at all. The
  manual-modprobe workaround above is specifically a UTM/QEMU
  virtualization gap, not the general case for bare metal — applying
  it unconditionally to real hardware is solving a problem that
  hardware doesn't have.
- **UTM/QEMU (and "most cloud hypervisors" per the existing
  group_vars comment)** — `snd_hda_intel`, plus
  `linux-modules-extra-$(uname -r)` to make the module available at
  all, per the sequence above.
- **Headless cloud installs with no virtual audio device at all (e.g.
  a bare DigitalOcean droplet)** — needs a dummy ALSA driver
  (`snd-dummy`) just so ALSA/`caed` have something to bind to, not
  real playback.

## Open items for implementation time

Not designed yet — flagging the requirement and the shape of the
decision, not solving it here:

- What actually distinguishes these cases at provisioning time.
  `systemd-detect-virt` is the obvious starting point for
  bare-metal-vs-hypervisor (and can often name the hypervisor itself,
  e.g. `qemu`), but HPI-hardware-presence needs its own explicit check
  (e.g. `lspci` matching AudioScience's vendor ID, or checking whether
  their kernel module/driver package is already present) run *before*
  any generic-ALSA branch, so HPI detection takes priority rather than
  being a fallback case.
- Whether detection should be fully automatic with a manual override
  available (consistent with `rivendell_install_mode` and
  `rivendell_target_os`'s existing pattern: explicit, overridable
  group_vars, not silently-magic auto-detection with no escape hatch),
  or detect-and-warn-if-overridden.
- Whether the "no virtual audio device, needs `snd-dummy`" case can
  reliably be told apart from "real audio hardware that the kernel just
  hasn't auto-loaded a driver for yet" — these can look similar from
  inside a freshly-booted VM before assuming "no device" is correct.

## Confirmed out of scope for this pass

- Implementing any of the detection logic above — this spec exists to
  name the requirement and the four cases it has to cover, not to ship
  it.
- Anything about which Rivendell git ref or OS this playbook targets —
  orthogonal to `0001-install-modes.md` (database/NFS topology) and
  `0002-arm64-debian-support.md` (OS/architecture); audio hardware
  detection applies independently of both.
