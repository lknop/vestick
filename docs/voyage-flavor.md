# Voyage-flavored redesign (branch: voyage-flavor)

The first cut of VEyage went the modern atomic-OS route: squashfs root + tmpfs
overlay + a separate state partition with per-path bind mounts. It works, but
the surface area is large — overlayroot patching, a state-init service that
bind-mounts the persisted paths back over the overlay, a custom firstboot
wizard with shadow-rewrite-in-place tricks to dodge bind-mount inode quirks.
Every new file you want to persist needs a code change.

This branch goes back to the **Voyage Linux** mental model — the system is
mounted read-only normally; the operator runs `remountrw`, makes the change,
then `remountro`. No overlay, no state partition for binds, no per-path
list. Just a normal Debian on a normal filesystem with a write switch.

The catch: Proxmox's `pve-cluster` (pmxcfs) writes to `/var/lib/pve-cluster/`
constantly — heartbeats, status, every config change. A pure Voyage model
where `/` is ro until the operator flips it doesn't survive pmxcfs starting.

So the adapted layout:

```
ESP                          (boot, FAT32, ~128 MB)
/                            ext4, mounted RO by default; remountrw on demand
/var/lib/pve-cluster         ext4, separate partition, always RW (~256 MB)
/var/lib/rrdcached           tmpfs (perf graphs reset on reboot — by design)
/tmp, /var/tmp, /var/log     tmpfs (logs forward via rsyslog)
/run                         tmpfs (systemd default)
```

## What this gives us

- **Operator UX is just Debian.** `apt upgrade` works (during a `remountrw`
  window). Editing any `/etc/foo.conf` persists. No "did I add this to
  PERSIST_PATHS?" surprise.
- **Single image, easy to dd.** No multi-partition state to keep separate.
  pmxcfs gets its own partition but it's part of the same disk image.
- **Squashfs's read-perf benefit is given up** — see "tradeoffs" below.
- **Most of this project's overlay code disappears.** No overlayroot patch,
  no veyage-state-init, no PERSIST_PATHS, no shadow rewrite-in-place.
  systemd-firstboot handles hostname/root-password natively because `/etc`
  is just normal writable storage now.
- **rrdcached on tmpfs eliminates the bulk of routine flash writes.** It's
  the chattiest writer on a Proxmox host and its data is genuinely
  disposable — losing perf graphs on reboot bothers nobody.

## Operator workflow

```sh
# Change anything
remountrw
vi /etc/network/interfaces
remountro

# Upgrade
remountrw
apt update && apt upgrade -y
remountro

# Reboot — change persists
```

A systemd timer auto-runs `remountro` after 10 min of unattended rw, in
case the operator forgets. This is what later Voyage builds did.

## Tradeoffs vs. the original design

| Property | Original (squashfs+overlay) | Voyage-flavored |
|---|---|---|
| Read perf on slow flash | excellent (compressed sequential reads) | normal ext4 (worse on cheap USB) |
| Boot speed on USB 2.0 | fast (less data to read) | slower (more data, random access) |
| `apt upgrade` works in place | no (writes vanish on reboot) | **yes**, during rw window |
| Power-loss exposure | none on /, only on state partition | rw window (operator-controlled) + pmxcfs partition |
| Atomic rollback after upgrade | possible with RAUC + A/B | not without adding A/B layout |
| Code surface in this project | ~500 lines overlay + scripts | ~100 lines |
| Operator surprise factor | high (custom mental model) | low (it's Debian) |

If the **read-perf / atomic-upgrade / immutability** properties matter for
your deployment, the original main-branch design is the right choice and
this branch is the wrong one. If you want a Proxmox-on-USB image with
normal Linux semantics and minimal write activity, this is.

## What stays from main

- `journald Storage=volatile` (logs in RAM)
- `rsyslog` forward profile (logs leave the box)
- `veyage-network-init` (interactive vmbr0 picker — there's no good
  systemd-shipped substitute; an interface picker is genuinely needed)
- The Phase 5 sshd drop-in (`PermitRootLogin yes`)
- The GitHub Actions workflow (just builds a different image)

## What goes away

- `overlay/etc/overlayroot.conf`
- `overlay/etc/systemd/system/mnt-state.mount`
- `overlay/etc/systemd/system/veyage-state.service`
- `overlay/usr/local/sbin/veyage-state-init`
- `overlay/etc/systemd/system/veyage-firstboot.service` (replaced by systemd-firstboot)
- `overlay/usr/local/sbin/veyage-firstboot`
- The overlayroot patch in `build.sh::configure_readonly`
- The squashfs pack step in `build.sh::pack_squashfs`
- The `MODE=direct` path in `test-vm.sh` (only useful for the squashfs design)
- `packages/base.list` no longer needs `overlayroot`, `busybox` (the latter
  was only there as initramfs glue for overlayroot)

## What's new

- `overlay/usr/local/sbin/remountrw` and `remountro`
- `overlay/etc/systemd/system/auto-remount-ro.service` + `.timer`
- `overlay/etc/fstab` with `/` ro, pmxcfs partition, tmpfs lines
- A systemd-firstboot service drop-in to limit prompts to hostname +
  root password (no locale/keymap/timezone)
- `build.sh` rewritten around `debootstrap → mounted ext4 image` instead of
  `debootstrap → chroot → squashfs → image`

## Open questions

- **Auto-remount-ro timer interval**: 10 min default. Configurable?
- **`/etc/fstab` `errors=` policy on /**: `errors=remount-ro` is appropriate
  for the ro design. Or `errors=panic` to force a reboot?
- **Image size default**: ext4 root needs more space than the squashfs did
  (no compression). Probably 2 GB without Proxmox, 4 GB with. Default to 4 GB
  and let users `resize2fs` after dd to a bigger device.
- **First-boot resize**: same growpart pattern still applies — grow the root
  partition to fill the device after dd to a larger USB.
